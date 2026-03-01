defmodule Stc.Scheduler.Runtime do
  @moduledoc """
  Scheduler runtime state management: agent health transitions, task lifecycle, and cleanup.

  ## Agent pool

  `state.agent_pool` is a `%{status :: atom() => [Agent.t()]}` map grouping agents by their
  current status. Active agents are under the `:active` key; unhealthy or unavailable agents
  appear under their respective status keys. `select_agents_for_event` reads
  `state.agent_pool[:active]` directly, so algorithm implementors never need to filter by
  status themselves. `reconcile_stale_agents` receives the full map and can inspect any bucket.

  `check_transitions/2` is called each tick after `refresh_agent_pool`. It diffs the new pool
  against the previous snapshot and starts or cancels per-agent health-toleration timers.
  When a timer expires the scheduler receives `{:agent_eviction_timeout, agent_id}` and calls
  `handle_eviction_timeout/2`, which invokes the algorithm's `on_agent_eviction/3` callback.

  ## Task lifecycle

  `teardown_task/2` is the single authoritative terminal-cleanup function. It:

  - Releases the distributed lock held by the scheduler for this task.
  - Prunes the task_id from `stopped_task_ids` (prevents unbounded growth).
  - Removes the task from all active-tracking maps (`active_tasks`, `agent_tasks`,
    `workflow_tasks`, `active_task_info`), pruning empty workflow entries.

  It is idempotent and called from both event-based paths (`Completed`, `Failed`) and the
  executor `:DOWN` handler, whichever fires first; the second call is a no-op.

  ## Agent status semantics

  - `:active`      — healthy, eligible for new tasks
  - `:unhealthy`   — degraded but possibly transient; tolerated for
                     `unhealthy_toleration_ms` (default: 5 minutes) before eviction
  - `:unavailable` — definitively gone; tolerated for `unavailable_toleration_ms`
                     (default: 0 ms — immediate eviction)
  - Any other status, or absent from the pool entirely, is treated as `:unavailable`.
  """

  alias Stc.Event.Store
  alias Stc.Scheduler.State

  @default_unhealthy_toleration_ms :timer.minutes(5)
  @default_unavailable_toleration_ms 0

  @doc """
  Diffs the current `state.agent_pool` against `old_pool` (the previous tick's snapshot)
  and starts or cancels health-toleration timers as needed.
  """
  @spec check_transitions(State.t(), %{atom() => [Stc.Agent.t()]}) :: State.t()
  def check_transitions(%State{} = state, old_pool) do
    new_by_id = pool_by_id(state.agent_pool)
    old_by_id = pool_by_id(old_pool)

    state
    |> apply_pool_health(new_by_id)
    |> apply_disappeared(old_by_id, new_by_id)
  end

  @doc """
  Handles an `{:agent_eviction_timeout, agent_id}` message.

  Looks up the agent, collects its active tasks, calls `on_agent_eviction/3`,
  and dispatches `:preempt` or `{:cancel, reason}` messages to executors.
  Returns `{:noreply, new_state}` ready for the GenServer to return.
  """
  @spec handle_eviction_timeout(String.t(), State.t()) :: {:noreply, State.t()}
  def handle_eviction_timeout(agent_id, %State{} = state) do
    case Map.get(state.agent_health_timers, agent_id) do
      nil ->
        # Timer was cancelled or agent recovered — nothing to do.
        {:noreply, state}

      {_ref, agent} ->
        evicting = %{state | agent_health_timers: Map.delete(state.agent_health_timers, agent_id)}
        affected = active_tasks_for_agent(evicting, agent_id)
        actions = evicting.algorithm.on_agent_eviction(agent, affected, evicting)
        new_state = Enum.reduce(actions, evicting, &apply_eviction_action(&1, agent_id, &2))
        {:noreply, new_state}
    end
  end

  @doc """
  Handles a `Preempted` event dispatched from the event log.

  Tears down task tracking, releases the lock so the re-emitted `Ready` can
  acquire it fresh, and re-emits `Event.Ready` if the scheduler initiated the
  preemption (i.e. the task is in `preempting_task_ids`).
  """
  @spec handle_preempted(String.t(), State.t()) :: State.t()
  def handle_preempted(task_id, %State{} = state) do
    ready = Map.get(state.active_task_info, task_id)

    state
    |> teardown_task(task_id)
    |> maybe_reschedule(task_id, ready)
  end

  @doc """
  Full terminal cleanup: releases the distributed lock, prunes `stopped_task_ids`,
  and removes the task from all active-tracking maps.

  Idempotent — safe to call from both the event handler and the `:DOWN` handler.
  """
  @spec teardown_task(State.t(), String.t()) :: State.t()
  def teardown_task(%State{} = state, task_id) do
    state
    |> release_task_lock(task_id)
    |> remove_from_stopped(task_id)
    |> cleanup_task(task_id)
  end

  @doc "Removes a task from all active-task tracking maps. Prefer `teardown_task/2` on terminal paths."
  @spec cleanup_task(State.t(), String.t()) :: State.t()
  def cleanup_task(%State{active_tasks: active} = state, task_id)
      when is_map_key(active, task_id) do
    {_pid, new_active} = Map.pop(active, task_id)

    new_agent_tasks =
      Map.new(state.agent_tasks, fn {aid, task_ids} ->
        {aid, Enum.reject(task_ids, &(&1 == task_id))}
      end)

    # Prune entries whose task list became empty to prevent unbounded growth.
    new_workflow_tasks =
      Enum.reduce(state.workflow_tasks, %{}, fn {wf, ids}, acc ->
        case Enum.reject(ids, &(&1 == task_id)) do
          [] -> acc
          filtered -> Map.put(acc, wf, filtered)
        end
      end)

    %State{
      state
      | active_tasks: new_active,
        agent_tasks: new_agent_tasks,
        workflow_tasks: new_workflow_tasks,
        active_task_info: Map.delete(state.active_task_info, task_id)
    }
  end

  def cleanup_task(%State{} = state, _task_id), do: state

  #
  # private
  #

  # Flatten a status-bucketed pool map to %{agent_id => Agent.t()} for diff logic.
  @spec pool_by_id(%{atom() => [Stc.Agent.t()]}) :: %{String.t() => Stc.Agent.t()}
  defp pool_by_id(pool) do
    pool
    |> Map.values()
    |> List.flatten()
    |> Map.new(&{&1.id, &1})
  end

  @spec apply_pool_health(State.t(), %{String.t() => Stc.Agent.t()}) :: State.t()
  defp apply_pool_health(state, new_by_id) do
    Enum.reduce(new_by_id, state, fn {agent_id, agent}, acc ->
      transition_for_status(acc, agent, agent_id, agent.status)
    end)
  end

  @spec transition_for_status(State.t(), Stc.Agent.t(), String.t(), atom()) :: State.t()
  defp transition_for_status(state, _agent, agent_id, :active) do
    cancel_timer(state, agent_id)
  end

  defp transition_for_status(state, agent, agent_id, :unhealthy) do
    start_timer_if_needed(state, agent, agent_id, @default_unhealthy_toleration_ms)
  end

  defp transition_for_status(state, agent, agent_id, :unavailable) do
    # :unavailable is more severe — upgrade any existing :unhealthy timer.
    state
    |> cancel_timer(agent_id)
    |> start_timer_if_needed(agent, agent_id, @default_unavailable_toleration_ms)
  end

  defp transition_for_status(state, _agent, _agent_id, _unknown), do: state

  @spec apply_disappeared(State.t(), %{String.t() => Stc.Agent.t()}, %{
          String.t() => Stc.Agent.t()
        }) :: State.t()
  defp apply_disappeared(state, old_by_id, new_by_id) do
    disappeared = Map.keys(old_by_id) -- Map.keys(new_by_id)

    Enum.reduce(disappeared, state, fn agent_id, acc ->
      case Map.get(old_by_id, agent_id) do
        nil ->
          acc

        agent ->
          gone = %{agent | status: :unavailable}

          acc
          |> cancel_timer(agent_id)
          |> start_timer_if_needed(gone, agent_id, @default_unavailable_toleration_ms)
      end
    end)
  end

  @spec cancel_timer(State.t(), String.t()) :: State.t()
  defp cancel_timer(%State{agent_health_timers: timers} = state, agent_id) do
    case Map.pop(timers, agent_id) do
      {nil, _} ->
        state

      {{ref, _agent}, new_timers} ->
        Process.cancel_timer(ref)
        %{state | agent_health_timers: new_timers}
    end
  end

  @spec start_timer_if_needed(State.t(), Stc.Agent.t(), String.t(), non_neg_integer()) ::
          State.t()
  defp start_timer_if_needed(%State{} = state, agent, agent_id, tolerance_ms) do
    has_tasks? = not Enum.empty?(Map.get(state.agent_tasks, agent_id, []))
    already_timing? = Map.has_key?(state.agent_health_timers, agent_id)

    if has_tasks? and not already_timing? do
      ref = Process.send_after(self(), {:agent_eviction_timeout, agent_id}, tolerance_ms)
      %{state | agent_health_timers: Map.put(state.agent_health_timers, agent_id, {ref, agent})}
    else
      state
    end
  end

  @spec release_task_lock(State.t(), String.t()) :: State.t()
  defp release_task_lock(%State{} = state, task_id) do
    lock = Map.get(state.task_locks, task_id)
    if lock, do: Store.release_lock(task_id, lock)
    %{state | task_locks: Map.delete(state.task_locks, task_id)}
  end

  @spec remove_from_stopped(State.t(), String.t()) :: State.t()
  defp remove_from_stopped(%State{stopped_task_ids: nil} = state, _task_id), do: state

  defp remove_from_stopped(%State{} = state, task_id) do
    %{state | stopped_task_ids: MapSet.delete(state.stopped_task_ids, task_id)}
  end

  @spec active_tasks_for_agent(State.t(), String.t()) :: [{String.t(), Stc.Event.Ready.t()}]
  defp active_tasks_for_agent(%State{} = state, agent_id) do
    state.agent_tasks
    |> Map.get(agent_id, [])
    |> Enum.flat_map(&task_id_to_ready(state, &1))
  end

  @spec task_id_to_ready(State.t(), String.t()) :: [{String.t(), Stc.Event.Ready.t()}]
  defp task_id_to_ready(%State{active_task_info: info}, task_id) do
    case Map.get(info, task_id) do
      nil -> []
      %Stc.Event.Ready{} = ready -> [{task_id, ready}]
    end
  end

  @spec apply_eviction_action({:reschedule | :fail, String.t()}, String.t(), State.t()) ::
          State.t()
  defp apply_eviction_action({:reschedule, task_id}, agent_id, state) do
    case Map.get(state.active_tasks, task_id) do
      nil ->
        state

      pid ->
        send(pid, {:preempt, {:agent_eviction, agent_id}})
        %{state | preempting_task_ids: MapSet.put(state.preempting_task_ids, task_id)}
    end
  end

  defp apply_eviction_action({:fail, task_id}, agent_id, state) do
    case Map.get(state.active_tasks, task_id) do
      nil -> :ok
      pid -> send(pid, {:cancel, {:agent_unavailable, agent_id}})
    end

    state
  end

  @spec maybe_reschedule(State.t(), String.t(), Stc.Event.Ready.t() | nil) :: State.t()
  defp maybe_reschedule(%State{} = state, task_id, ready) do
    if task_id in state.preempting_task_ids do
      maybe_reemit_ready(ready)
      %{state | preempting_task_ids: MapSet.delete(state.preempting_task_ids, task_id)}
    else
      state
    end
  end

  @spec maybe_reemit_ready(Stc.Event.Ready.t() | nil) :: :ok
  defp maybe_reemit_ready(nil), do: :ok

  defp maybe_reemit_ready(%Stc.Event.Ready{} = ready) do
    Store.append(%{ready | timestamp: DateTime.utc_now(), schedule_attempts: 0})
    :ok
  end
end
