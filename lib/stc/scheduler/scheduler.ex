defmodule Stc.Scheduler do
  @moduledoc """
  A generic, deterministic task scheduler.

  ## Event consumption

  Each tick the scheduler fetches all new events since `event_cursor` from the `EventLog`
  and advances the cursor. This is a single pull per tick; the scheduler never depends on
  backend push semantics. Incoming events modify scheduler state:

  - `Ready`     → lock + select agents + spawn executor; on failure emit `Event.Pending`
                  into the log with the blocking conditions. No in-memory retry buffer.
  - `Pending`   → re-attempt scheduling directly; on failure emit a new `Event.Pending`
                  with an incremented `schedule_attempts` counter.
  - `Preempted` → infrastructure-triggered stop; releases lock and re-emits `Ready` for
                  rescheduling on fresh agents (see `Stc.Scheduler.Runtime`).
  - `Started`   → no-op (scheduler has already handed off; executor drives this).
  - `Completed` → clean up active-task tracking.

  ## Distributed safety

  Lock acquisition is delegated to `Stc.Event.Store.try_lock/3`, which is atomic in
  all backends. Two schedulers racing on the same `Ready` event will never both
  succeed; the loser silently skips it.
  """

  use GenServer

  alias Stc.Event.Pending
  alias Stc.Event.Store
  alias Stc.ReplyBuffer
  alias Stc.Scheduler.Affinity
  alias Stc.Scheduler.Executor
  alias Stc.Scheduler.Runtime
  alias Stc.Scheduler.State
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

  @doc "Appends a Stop event for a single task; every scheduler acts on it independently."
  @spec stop_task(String.t(), reason :: term()) :: {:ok, term()} | {:error, term()}
  def stop_task(task_id, reason \\ :cancelled) do
    Store.append(%Stc.Event.Stop{task_id: task_id, reason: reason, timestamp: DateTime.utc_now()})
  end

  @doc "Appends a Stop event for all tasks in a workflow; every scheduler acts on it independently."
  @spec stop_workflow(String.t(), reason :: term()) :: {:ok, term()} | {:error, term()}
  def stop_workflow(workflow_id, reason \\ :cancelled) do
    Store.append(%Stc.Event.Stop{
      workflow_id: workflow_id,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
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

    state = %State{
      id: id,
      level: Keyword.get(opts, :level),
      agent_pool: %{},
      algorithm: Keyword.fetch!(opts, :algorithm),
      agent_tasks: %{},
      task_agents: %{},
      task_locks: %{},
      task_to_executor_pid: %{},
      executor_pid_to_task: %{},
      event_loop_ref: nil,
      event_cursor: Store.origin(),
      reply_buffer: nil,
      scheduler_tick_rate_ms:
        Keyword.get(opts, :scheduler_tick_rate_ms, @default_scheduler_tick_rate_ms),
      tags: Keyword.get(opts, :tags, []),
      space_id: Keyword.get(opts, :space_id, nil),
      cluster_id: Keyword.get(opts, :cluster_id, nil),
      workflow_tasks: %{},
      stopped_task_ids: MapSet.new(),
      agent_health_timers: %{},
      active_task_info: %{},
      preempting_task_ids: MapSet.new()
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %State{id: id} = state) do
    # On boot any lock we held in a previous incarnation is stale — we have no
    # active executors yet so no task can legitimately own a lock under our id.
    Store.release_locks_by_caller(id)

    {:ok, reply_buffer_pid} = ReplyBuffer.start_link(scheduler_id: id)
    state = %{state | reply_buffer: reply_buffer_pid}

    {:noreply, schedule_event_loop(state)}
  end

  @impl true
  def handle_info(:event_loop, %State{} = state) do
    old_pool = state.agent_pool

    state =
      state
      |> refresh_agent_pool()
      |> Runtime.check_transitions(old_pool)
      |> reconcile_stale_agents()
      |> process_agent_buffer()
      |> fetch_and_modify_state()

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

  @impl true
  def handle_info({:agent_eviction_timeout, agent_id}, %State{} = state) do
    Runtime.handle_eviction_timeout(agent_id, state)
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{executor_pid_to_task: pmap} = state
      )
      when is_map_key(pmap, pid) do
    task_id = Map.fetch!(pmap, pid)
    # handle_preempted reads active_task_info before teardown so a preempted executor
    # that dies before its Preempted event is processed still gets its Ready re-emitted.
    # For non-preempted tasks maybe_reschedule is a no-op.
    {:noreply, Runtime.handle_preempted(task_id, state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, state}
  end

  @spec schedule_event_loop(State.t()) :: State.t()
  defp schedule_event_loop(%State{event_loop_ref: nil} = state) do
    ref = Process.send_after(self(), :event_loop, state.scheduler_tick_rate_ms)
    %State{state | event_loop_ref: ref}
  end

  defp schedule_event_loop(%State{event_loop_ref: ref} = state) when is_reference(ref) do
    # Cancel only if the timer is still alive; ignore the return value — it may have
    # already fired by the time we get here.
    Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :event_loop, state.scheduler_tick_rate_ms)
    %State{state | event_loop_ref: new_ref}
  end

  # Pull all new events from the log since our cursor, then fold each into state.
  @spec fetch_and_modify_state(State.t()) :: State.t()
  defp fetch_and_modify_state(%State{event_cursor: cursor} = state) do
    {:ok, events, new_cursor} = Store.fetch(cursor, limit: 200)

    new_state = %State{state | event_cursor: new_cursor}

    events
    |> state.algorithm.schedule_event_order(new_state)
    |> Enum.reduce(new_state, &handle_event/2)
  end

  #
  ## Event -> state reducers
  #

  @spec handle_event(struct(), State.t()) :: State.t()
  defp handle_event(%Stc.Event.Ready{task_id: task_id} = event, %State{} = state) do
    if task_id in state.stopped_task_ids or not Affinity.matches_scheduler?(event, state) do
      state
    else
      do_schedule_ready(event, state)
    end
  end

  defp handle_event(%Pending{task_id: task_id} = pending, %State{} = state) do
    if task_id in state.stopped_task_ids or not Affinity.matches_scheduler?(pending, state) do
      state
    else
      do_schedule_ready(Pending.to_ready(pending), state)
    end
  end

  defp handle_event(%Stc.Event.Stop{task_id: nil, workflow_id: wf_id}, %State{} = state) do
    task_ids = Map.get(state.workflow_tasks, wf_id, MapSet.new())
    Enum.each(task_ids, &send_cancel(&1, state))
    new_stopped = Enum.reduce(task_ids, state.stopped_task_ids, &MapSet.put(&2, &1))
    %State{state | stopped_task_ids: new_stopped}
  end

  defp handle_event(%Stc.Event.Stop{task_id: task_id}, %State{} = state) do
    send_cancel(task_id, state)
    %State{state | stopped_task_ids: MapSet.put(state.stopped_task_ids, task_id)}
  end

  defp handle_event(%Stc.Event.Preempted{task_id: task_id}, %State{} = state) do
    Runtime.handle_preempted(task_id, state)
  end

  # planned - no terminal handling yet; struct exists for log visibility
  defp handle_event(%Stc.Event.Rejected{}, %State{} = state), do: state

  defp handle_event(%Stc.Event.Completed{task_id: task_id}, %State{} = state) do
    Runtime.teardown_task(state, task_id)
  end

  # Non-retriable failures are terminal; clean up the same way as completions.
  # Retriable failures leave the executor running (it reschedules itself internally).
  defp handle_event(%Stc.Event.Failed{retriable: false, task_id: task_id}, %State{} = state) do
    Runtime.teardown_task(state, task_id)
  end

  defp handle_event(%Stc.Event.Started{}, %State{} = state), do: state

  defp handle_event(_unknown, %State{} = state), do: state

  #
  ## Scheduling pipeline
  #

  @spec do_schedule_ready(Stc.Event.Ready.t(), State.t()) :: State.t()
  defp do_schedule_ready(%Stc.Event.Ready{} = event, %State{} = state) do
    case try_schedule_ready(event, state) do
      {:ok, new_state} ->
        new_state

      {:error, reason, new_state} when reason in [:no_capacity, :rejected] ->
        Store.append(Pending.from_ready(event, reason))
        new_state

      {:error, {:pending, _} = conditions, new_state} ->
        Store.append(Pending.from_ready(event, conditions))
        new_state

      {:error, _other, new_state} ->
        new_state
    end
  end

  @spec try_schedule_ready(Stc.Event.Ready.t(), State.t()) ::
          {:ok, State.t()}
          | {:error, :no_capacity | :locked | :rejected | :failed_to_spawn | {:pending, term()},
             State.t()}
  defp try_schedule_ready(%Stc.Event.Ready{} = event, %State{} = state) do
    with {:ok, locked_state} <- try_acquire_lock(event.task_id, state),
         {:ok, final_state} <- select_and_spawn(event, locked_state) do
      {:ok, final_state}
    else
      {:error, :locked} ->
        {:error, :locked, state}

      {:error, reason, ls} ->
        # Lock was acquired but no executor was spawned; release it so the task can be retried.
        {:error, reason, Runtime.teardown_task(ls, event.task_id)}
    end
  end

  # Runs the post-lock steps (agent selection, admit checks, executor spawn) as a unit.
  # Returns {:error, reason, locked_state} on any failure so the caller can release the lock.
  @spec select_and_spawn(Stc.Event.Ready.t(), State.t()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  defp select_and_spawn(%Stc.Event.Ready{} = event, %State{} = locked_state) do
    with {:ok, agents} <- select_agents_for_event(event, locked_state),
         :ok <- Affinity.check_admit_policies(event, agents, locked_state),
         {:ok, final_state} <- spawn_executor(event, agents, locked_state) do
      {:ok, final_state}
    else
      {:error, reason} -> {:error, reason, locked_state}
    end
  end

  @spec try_acquire_lock(String.t(), State.t()) :: {:ok, State.t()} | {:error, :locked}
  defp try_acquire_lock(task_id, %State{} = state) do
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
  defp select_agents_for_event(%Stc.Event.Ready{} = event, %State{} = state) do
    available =
      state.agent_pool
      |> Map.get(:active, [])
      |> Enum.filter(fn agent ->
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
  defp spawn_executor(%Stc.Event.Ready{} = event, agents, %State{} = state) do
    config = %{
      workflow_id: event.workflow_id,
      task_id: event.task_id,
      task_spec:
        Spec.new(event.module, event.payload,
          policies: event.policies,
          duration_ms: event.duration_ms
        ),
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
        # monitor so we can cleanup
        Process.monitor(pid)

        agent_ids = Enum.map(agents, & &1.id)

        {:ok,
         %State{
           state
           | task_to_executor_pid: Map.put(state.task_to_executor_pid, event.task_id, pid),
             executor_pid_to_task: Map.put(state.executor_pid_to_task, pid, event.task_id),
             agent_tasks: register_agent_tasks(state.agent_tasks, agents, event.task_id),
             task_agents: Map.put(state.task_agents, event.task_id, agent_ids),
             workflow_tasks:
               Map.update(
                 state.workflow_tasks,
                 event.workflow_id,
                 MapSet.new([event.task_id]),
                 &MapSet.put(&1, event.task_id)
               ),
             active_task_info: Map.put(state.active_task_info, event.task_id, event)
         }}

      {:error, _reason} ->
        {:error, :failed_to_spawn}
    end
  end

  @spec register_agent_tasks(
          %{String.t() => [String.t()]},
          [Stc.Agent.t()],
          String.t()
        ) :: %{String.t() => [String.t()]}
  defp register_agent_tasks(agent_tasks, agents, task_id) do
    Enum.reduce(agents, agent_tasks, fn agent, acc ->
      Map.update(acc, agent.id, [task_id], &[task_id | &1])
    end)
  end

  # tell the executor to cancel

  @spec send_cancel(String.t(), State.t()) :: :ok
  defp send_cancel(task_id, %State{task_to_executor_pid: active}) do
    case Map.get(active, task_id) do
      nil -> :ok
      pid -> send(pid, :cancel)
    end
  end

  @spec agent_is_free?(Stc.Agent.t(), State.t()) :: boolean()
  defp agent_is_free?(%{id: id}, %State{agent_tasks: agent_tasks}) do
    agent_tasks |> Map.get(id, []) |> Enum.empty?()
  end

  #
  ## Algorithm delegation
  #

  @spec refresh_agent_pool(State.t()) :: State.t()
  defp refresh_agent_pool(%State{} = state), do: state.algorithm.refresh_agent_pool(state)

  @spec reconcile_stale_agents(State.t()) :: State.t()
  defp reconcile_stale_agents(%State{} = state), do: state.algorithm.reconcile_stale_agents(state)

  @spec process_agent_buffer(State.t()) :: State.t()
  defp process_agent_buffer(%State{} = state), do: state.algorithm.process_agent_buffer(state)
end
