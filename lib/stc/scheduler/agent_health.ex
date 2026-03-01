defmodule Stc.Scheduler.AgentHealth do
  @moduledoc """
  Agent health transition tracking and eviction for the scheduler.

  The scheduler calls `check_transitions/2` each tick (after `refresh_agent_pool`)
  to diff the new agent pool against the previous one and manage per-agent
  health-toleration timers. When a timer expires the scheduler receives
  `{:agent_eviction_timeout, agent_id}` and calls `handle_eviction_timeout/2`,
  which invokes the algorithm's `on_agent_eviction/3` callback and dispatches
  the resulting `:reschedule` or `:fail` actions to executor processes.

  A preempted task emits `Event.Preempted`; the scheduler calls
  `handle_preempted/2` which releases the lock and re-emits `Event.Ready`
  so the task re-enters the normal scheduling pipeline on fresh agents.

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
  Diffs `new_pool` (already in `state.agent_pool`) against `old_pool` and
  starts or cancels health-toleration timers as needed.
  """
  @spec check_transitions(State.t(), [Stc.Agent.t()]) :: State.t()
  def check_transitions(%State{} = state, old_pool) do
    new_map = Map.new(state.agent_pool, &{&1.id, &1})
    old_map = Map.new(old_pool, &{&1.id, &1})

    state
    |> apply_pool_health(new_map)
    |> apply_disappeared(old_map, new_map)
  end

  @doc """
  Handles an `{:agent_eviction_timeout, agent_id}` message.

  Looks up the agent, collects its active tasks, calls `on_agent_eviction/3`,
  and dispatches `:preempt` or `{:cancel, reason}` messages to executors.
  Returns `{:noreply, new_state}` ready for the GenServer to return.
  """
  @spec handle_eviction_timeout(String.t(), State.t()) ::
          {:noreply, State.t()}
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

  Cleans up task tracking, releases the lock so the re-emitted `Ready` can
  acquire it fresh, and re-emits `Event.Ready` if the scheduler initiated the
  preemption (i.e. the task is in `preempting_task_ids`).
  """
  @spec handle_preempted(String.t(), State.t()) :: State.t()
  def handle_preempted(task_id, %State{} = state) do
    ready = Map.get(state.active_task_info, task_id)

    state
    |> cleanup_task(task_id)
    |> release_task_lock(task_id)
    |> maybe_reschedule(task_id, ready)
  end

  #
  # private
  #

  @spec apply_pool_health(State.t(), %{String.t() => Stc.Agent.t()}) :: State.t()
  defp apply_pool_health(state, new_map) do
    Enum.reduce(new_map, state, fn {agent_id, agent}, acc ->
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
  defp apply_disappeared(state, old_map, new_map) do
    disappeared = Map.keys(old_map) -- Map.keys(new_map)

    Enum.reduce(disappeared, state, fn agent_id, acc ->
      case Map.get(old_map, agent_id) do
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

  @spec release_task_lock(State.t(), String.t()) :: State.t()
  defp release_task_lock(%State{} = state, task_id) do
    lock = Map.get(state.task_locks, task_id)
    if lock, do: Store.release_lock(task_id, lock)
    %{state | task_locks: Map.delete(state.task_locks, task_id)}
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

  @doc "Removes a task from all active-task tracking maps. Called by the scheduler on Completed/Failed/Preempted."
  @spec cleanup_task(State.t(), String.t()) :: State.t()
  def cleanup_task(%State{active_tasks: active} = state, task_id)
      when is_map_key(active, task_id) do
    {_pid, new_active} = Map.pop(active, task_id)

    new_agent_tasks =
      Map.new(state.agent_tasks, fn {aid, task_ids} ->
        {aid, Enum.reject(task_ids, &(&1 == task_id))}
      end)

    new_workflow_tasks =
      Map.new(state.workflow_tasks, fn {wf, ids} ->
        {wf, Enum.reject(ids, &(&1 == task_id))}
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
end
