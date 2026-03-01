defmodule Stc.Scheduler do
  @moduledoc """
  A generic, deterministic task scheduler.

  ## Event consumption

  Each tick the scheduler fetches all new events since `event_cursor` from the `EventLog`
  and advances the cursor. This is a single pull per tick; the scheduler never depends on
  backend push semantics. Each event is dispatched:

  - `Ready`   → lock + select agents + spawn executor; on failure emit `Event.Pending`
                into the log with the blocking conditions. No in-memory retry buffer.
  - `Pending` → re-attempt scheduling directly; on failure emit a new `Event.Pending`
                with an incremented `schedule_attempts` counter.
  - `Started`   → no-op (scheduler has already handed off; executor drives this).
  - `Completed` → clean up active-task tracking.

  ## Distributed safety

  Lock acquisition is delegated to `Stc.Event.Store.try_lock/3`, which is atomic in
  all backends. Two schedulers racing on the same `Ready` event will never both
  succeed; the loser silently skips it.
  """

  use GenServer

  alias Stc.Event.Store
  alias Stc.ReplyBuffer
  alias Stc.Scheduler.Executor
  alias Stc.Scheduler.State
  alias Stc.Task.Context
  alias Stc.Task.Spec

  require Logger

  @default_scheduler_tick_rate_ms :timer.seconds(1)

  @doc false
  def via(id) do
    {:via, Horde.Registry, {Stc.SchedulerRegistry, "scheduler_#{id}"}}
  end

  @doc "Returns the current state of the scheduler with the given id, or nil if not found."
  @spec get_state(String.t()) :: State.t() | nil
  def get_state(id) do
    case Horde.Registry.lookup(Stc.SchedulerRegistry, "scheduler_#{id}") do
      [{pid, _}] -> :sys.get_state(pid, 5_000)
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Returns [{id, pid}] for all running schedulers visible in the Horde registry."
  @spec list() :: [{String.t(), pid()}]
  def list do
    Stc.SchedulerRegistry
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {"scheduler_" <> id, pid} -> [{id, pid}]
      _ -> []
    end)
  rescue
    _ -> []
  end

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    # On boot any lock we held in a previous incarnation is stale — we have no
    # active executors yet so no task can legitimately own a lock under our id.
    Store.release_locks_by_caller(id)

    {:ok, reply_buffer_pid} = ReplyBuffer.start_link(scheduler_id: id)

    state = %State{
      id: id,
      level: Keyword.get(opts, :level),
      agent_pool: [],
      stale_agent_pool: [],
      algorithm: Keyword.fetch!(opts, :algorithm),
      agent_tasks: %{},
      task_locks: %{},
      active_tasks: %{},
      event_loop_ref: nil,
      event_cursor: Store.origin(),
      reply_buffer: reply_buffer_pid,
      scheduler_tick_rate_ms:
        Keyword.get(opts, :scheduler_tick_rate_ms, @default_scheduler_tick_rate_ms),
      tags: Keyword.get(opts, :tags, []),
      space_id: Keyword.get(opts, :space_id, nil),
      cluster_id: Keyword.get(opts, :cluster_id, nil)
    }

    {:ok, schedule_event_loop(state)}
  end

  @impl true
  def handle_info(:event_loop, %State{} = state) do
    state =
      state
      |> refresh_agent_pool()
      |> reconcile_stale_agents()
      |> process_agent_buffer()
      |> fetch_and_dispatch_new_events()

    Logger.debug("Scheduler #{state.id} event loop completed.")

    {:noreply, schedule_event_loop(state)}
  rescue
    err ->
      Logger.error(
        "Rescued error in scheduler #{state.id} event loop: " <>
          Exception.format(:error, err, __STACKTRACE__)
      )

      {:noreply, schedule_event_loop(state)}
  catch
    kind, payload ->
      Logger.error(
        "Caught error in scheduler #{state.id} event loop: " <>
          Exception.format(kind, payload, __STACKTRACE__)
      )

      {:noreply, schedule_event_loop(state)}
  end

  @spec schedule_event_loop(State.t()) :: State.t()
  def schedule_event_loop(%State{event_loop_ref: nil} = state) do
    ref = Process.send_after(self(), :event_loop, state.scheduler_tick_rate_ms)
    %State{state | event_loop_ref: ref}
  end

  def schedule_event_loop(%State{event_loop_ref: ref} = state) when is_reference(ref) do
    # Cancel only if the timer is still alive; ignore the return value — it may have
    # already fired by the time we get here.
    Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :event_loop, state.scheduler_tick_rate_ms)
    %State{state | event_loop_ref: new_ref}
  end

  # Pull all new events from the log since our cursor, then dispatch each.
  @spec fetch_and_dispatch_new_events(State.t()) :: State.t()
  defp fetch_and_dispatch_new_events(%State{event_cursor: cursor} = state) do
    {:ok, events, new_cursor} = Store.fetch(cursor, limit: 200)

    new_state = %State{state | event_cursor: new_cursor}

    events
    |> state.algorithm.schedule_event_order(new_state)
    |> Enum.reduce(new_state, &dispatch_event/2)
  end

  @spec dispatch_event(struct(), State.t()) :: State.t()
  defp dispatch_event(%Stc.Event.Ready{} = event, %State{} = state) do
    if matches_this_scheduler?(event, state) do
      case try_schedule_ready(event, state) do
        {:ok, new_state} ->
          new_state

        {:error, :no_capacity, new_state} ->
          emit_pending(event, :no_capacity)
          new_state

        {:error, {:pending, cond}, new_state} ->
          emit_pending(event, cond)
          new_state

        {:error, :rejected, new_state} ->
          emit_pending(event, :rejected)
          new_state

        {:error, _other, new_state} ->
          new_state
      end
    else
      state
    end
  end

  defp dispatch_event(%Stc.Event.Pending{} = pending, %State{} = state) do
    if matches_this_scheduler?(pending, state) do
      ready = pending_to_ready(pending)

      case try_schedule_ready(ready, state) do
        {:ok, new_state} ->
          new_state

        {:error, :no_capacity, new_state} ->
          emit_pending(ready, :no_capacity)
          new_state

        {:error, {:pending, cond}, new_state} ->
          emit_pending(ready, cond)
          new_state

        {:error, :rejected, new_state} ->
          emit_pending(ready, :rejected)
          new_state

        {:error, _other, new_state} ->
          new_state
      end
    else
      state
    end
  end

  # planned - no terminal handling yet; struct exists for log visibility
  defp dispatch_event(%Stc.Event.Rejected{}, %State{} = state), do: state

  defp dispatch_event(%Stc.Event.Completed{task_id: task_id}, %State{} = state) do
    cleanup_task(state, task_id)
  end

  defp dispatch_event(%Stc.Event.Started{}, %State{} = state), do: state

  defp dispatch_event(_unknown, %State{} = state), do: state

  @spec matches_this_scheduler?(Stc.Event.Ready.t() | Stc.Event.Pending.t(), State.t()) ::
          boolean()
  defp matches_this_scheduler?(
         %{scheduler_affinity: sa, space_affinity: spa, cluster_affinity: ca},
         state
       ) do
    tags_match?(sa, state.tags) and
      space_match?(spa, state.space_id) and
      cluster_match?(ca, state.cluster_id)
  end

  defp tags_match?(nil, _), do: true
  defp tags_match?(_, []), do: false
  defp tags_match?(task_tags, scheduler_tags), do: Enum.any?(task_tags, &(&1 in scheduler_tags))

  defp space_match?(nil, _), do: true
  defp space_match?(_, nil), do: false
  defp space_match?(a, b), do: a == b

  defp cluster_match?(nil, _), do: true
  defp cluster_match?(_, nil), do: false
  defp cluster_match?(a, b), do: a == b

  @spec try_schedule_ready(Stc.Event.Ready.t(), State.t()) ::
          {:ok, State.t()}
          | {:error, :no_capacity | :locked | :rejected | :failed_to_spawn | {:pending, term()},
             State.t()}
  defp try_schedule_ready(%Stc.Event.Ready{} = event, %State{} = state) do
    with {:ok, locked_state} <- try_acquire_lock(event.task_id, state),
         {:ok, agents} <- select_agents_for_event(event, locked_state),
         :ok <- check_admit_policies(event, agents, locked_state),
         {:ok, final_state} <- spawn_executor(event, agents, locked_state) do
      {:ok, final_state}
    else
      {:error, :locked} -> {:error, :locked, state}
      {:error, :no_capacity} -> {:error, :no_capacity, state}
      {:error, :rejected} -> {:error, :rejected, state}
      {:error, {:pending, cond}} -> {:error, {:pending, cond}, state}
      {:error, :failed_to_spawn} -> {:error, :failed_to_spawn, state}
    end
  end

  @spec check_admit_policies(Stc.Event.Ready.t(), [Stc.Agent.t()], State.t()) ::
          :ok | {:error, :rejected | {:pending, term()}}
  defp check_admit_policies(%Stc.Event.Ready{policies: nil}, _agents, _state), do: :ok
  defp check_admit_policies(%Stc.Event.Ready{policies: %{admit: []}}, _agents, _state), do: :ok

  defp check_admit_policies(%Stc.Event.Ready{policies: %{admit: policies}} = event, agents, state) do
    context = %Context{
      workflow_id: event.workflow_id,
      task_id: event.task_id,
      agents: agents,
      task_spec: Spec.new(event.module, event.payload, policies: event.policies),
      attempt: 1,
      cluster_id: nil,
      space_id: nil,
      reply_buffer: state.reply_buffer
    }

    Enum.reduce_while(policies, :ok, fn policy, _ ->
      case policy.__struct__.admit(policy, context) do
        :ok ->
          {:cont, :ok}

        {:pending, cond} ->
          {:halt, {:error, {:pending, cond}}}

        {:reject, reason} ->
          Logger.warning(
            "Task #{event.task_id} rejected by #{inspect(policy.__struct__)}: #{inspect(reason)}"
          )

          {:halt, {:error, :rejected}}
      end
    end)
  end

  @spec pending_to_ready(Stc.Event.Pending.t()) :: Stc.Event.Ready.t()
  defp pending_to_ready(%Stc.Event.Pending{} = p) do
    %Stc.Event.Ready{
      workflow_id: p.workflow_id,
      task_id: p.task_id,
      module: p.module,
      payload: p.payload,
      policies: p.policies,
      space_affinity: p.space_affinity,
      cluster_affinity: p.cluster_affinity,
      scheduler_affinity: p.scheduler_affinity,
      content_hash: p.content_hash,
      schedule_attempts: p.schedule_attempts,
      timestamp: DateTime.utc_now()
    }
  end

  @spec emit_pending(Stc.Event.Ready.t(), term()) :: {:ok, term()} | {:error, term()}
  defp emit_pending(%Stc.Event.Ready{} = event, conditions) do
    Store.append(%Stc.Event.Pending{
      workflow_id: event.workflow_id,
      task_id: event.task_id,
      module: event.module,
      payload: event.payload,
      policies: event.policies,
      space_affinity: event.space_affinity,
      cluster_affinity: event.cluster_affinity,
      scheduler_affinity: event.scheduler_affinity,
      content_hash: event.content_hash,
      conditions: conditions,
      schedule_attempts: event.schedule_attempts + 1,
      last_schedule_attempt: DateTime.utc_now(),
      timestamp: DateTime.utc_now()
    })
  end

  @spec try_acquire_lock(String.t(), State.t()) :: {:ok, State.t()} | {:error, :locked}
  def try_acquire_lock(task_id, %State{} = state) do
    lock = :erlang.unique_integer()

    case Store.try_lock(task_id, lock, state.id) do
      {:ok, ^lock} ->
        {:ok, put_in(state.task_locks[task_id], lock)}

      {:ok, _other_lock} ->
        # Re-entrant: same caller already holds it; treat as success.
        {:ok, state}

      {:error, :locked} ->
        {:error, :locked}
    end
  end

  @spec select_agents_for_event(Stc.Event.Ready.t(), State.t()) ::
          {:ok, [Stc.Agent.t()]} | {:error, :no_capacity}
  def select_agents_for_event(%Stc.Event.Ready{} = event, %State{} = state) do
    available =
      Enum.filter(state.agent_pool, fn agent ->
        state.algorithm.agent_matches_requirements?(agent, event) and
          (agent_is_free?(agent, state) or state.algorithm.can_oversubscribe?(agent, event, state))
      end)

    case available do
      [] ->
        Logger.warning("No capacity for event #{inspect(event)}")
        {:error, :no_capacity}

      [_ | _] ->
        state.algorithm.select_agents_for_event(event, available, state)
    end
  end

  @spec spawn_executor(Stc.Event.Ready.t(), [Stc.Agent.t()], State.t()) ::
          {:ok, State.t()} | {:error, :failed_to_spawn}
  def spawn_executor(%Stc.Event.Ready{} = event, agents, %State{} = state) do
    config = %{
      workflow_id: event.workflow_id,
      task_id: event.task_id,
      task_spec: Spec.new(event.module, event.payload, policies: event.policies),
      agents: agents,
      agent_ids: Enum.map(agents, & &1.id),
      scheduler_id: state.id,
      reply_buffer: state.reply_buffer,
      attempt: 1,
      cluster_id: nil,
      space_id: nil,
      content_hash: event.content_hash
    }

    case Executor.start_link(config) do
      {:ok, pid} ->
        new_active = Map.put(state.active_tasks, event.task_id, pid)

        new_agent_tasks =
          Enum.reduce(agents, state.agent_tasks, fn agent, acc ->
            Map.update(acc, agent.id, [event.task_id], &[event.task_id | &1])
          end)

        {:ok, %State{state | active_tasks: new_active, agent_tasks: new_agent_tasks}}

      {:error, _reason} ->
        {:error, :failed_to_spawn}
    end
  end

  @spec cleanup_task(State.t(), String.t()) :: State.t()
  defp cleanup_task(%State{active_tasks: active} = state, task_id)
       when is_map_key(active, task_id) do
    {_pid, new_active} = Map.pop(active, task_id)

    new_agent_tasks =
      Map.new(state.agent_tasks, fn {agent_id, task_ids} ->
        {agent_id, List.delete(task_ids, task_id)}
      end)

    %State{state | active_tasks: new_active, agent_tasks: new_agent_tasks}
  end

  defp cleanup_task(%State{} = state, _task_id), do: state

  @spec refresh_agent_pool(State.t()) :: State.t()
  def refresh_agent_pool(%State{} = state), do: state.algorithm.refresh_agent_pool(state)

  @spec reconcile_stale_agents(State.t()) :: State.t()
  def reconcile_stale_agents(%State{} = state), do: state.algorithm.reconcile_stale_agents(state)

  @spec process_agent_buffer(State.t()) :: State.t()
  def process_agent_buffer(%State{} = state), do: state.algorithm.process_agent_buffer(state)

  @spec schedule_event_order([struct()], State.t()) :: [struct()]
  def schedule_event_order(events, %State{} = state),
    do: state.algorithm.schedule_event_order(events, state)

  @spec agent_is_free?(Stc.Agent.t(), State.t()) :: boolean()
  defp agent_is_free?(%{id: id}, %State{agent_tasks: agent_tasks}) do
    agent_tasks |> Map.get(id, []) |> Enum.empty?()
  end
end
