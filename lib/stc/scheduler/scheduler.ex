defmodule Stc.Scheduler do
  @moduledoc """
  A generic, deterministic task scheduler.

  ## Event consumption

  Each tick the scheduler:

  1. Retries `pending_ready` — `Ready` events buffered from prior ticks because no
     agents had capacity.
  2. Fetches all new events since `event_cursor` from the `EventLog` and advances the
     cursor. This is a single pull per tick; the scheduler never depends on backend push
     semantics.
  3. Dispatches each event to `schedule_task/2`:
     - `Ready`     → lock + select agents + spawn executor; on failure keep in
                     `pending_ready`.
     - `Started`   → no-op (scheduler has already handed off; executor drives this).
     - `Completed` → clean up active-task tracking.

  ## Distributed safety

  Lock acquisition is delegated to `Stc.Event.Store.try_lock/3`, which is atomic in
  all backends. Two schedulers racing on the same `Ready` event will never both
  succeed; the loser silently skips it.
  """

  use GenServer

  require Logger

  alias Stc.Event.Store
  alias Stc.Scheduler.Executor
  alias Stc.Task.Spec
  alias Stc.ReplyBuffer
  alias Stc.Scheduler.State

  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(id) do
    {:via, Horde.Registry, {Stc.SchedulerRegistry, "scheduler_#{id}"}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @impl GenServer
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
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
      pending_ready: [],
      reply_buffer: reply_buffer_pid
    }

    {:ok, schedule_event_loop(state)}
  end

  @impl GenServer
  def handle_info(:event_loop, %State{} = state) do
    state =
      state
      |> refresh_agent_pool()
      |> reconcile_stale_agents()
      |> process_agent_buffer()
      |> retry_pending_ready()
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
    ref = Process.send_after(self(), :event_loop, :timer.seconds(1))
    %State{state | event_loop_ref: ref}
  end

  def schedule_event_loop(%State{event_loop_ref: ref} = state) when is_reference(ref) do
    # Cancel only if the timer is still alive; ignore the return value — it may have
    # already fired by the time we get here.
    Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :event_loop, :timer.seconds(1))
    %State{state | event_loop_ref: new_ref}
  end

  # Retry Ready events that had no agent capacity on a previous tick.
  @spec retry_pending_ready(State.t()) :: State.t()
  defp retry_pending_ready(%State{pending_ready: []} = state), do: state

  defp retry_pending_ready(%State{pending_ready: pending} = state) do
    {still_pending, %State{} = new_state} =
      Enum.reduce(pending, {[], state}, fn %Stc.Event.Ready{} = event, {acc_pending, acc_state} ->
        case try_schedule_ready(event, acc_state) do
          {:ok, next_state} -> {acc_pending, next_state}
          {:error, :no_capacity, next_state} -> {[event | acc_pending], next_state}
          {:error, _other, next_state} -> {acc_pending, next_state}
        end
      end)

    %State{new_state | pending_ready: Enum.reverse(still_pending)}
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
    case try_schedule_ready(event, state) do
      {:ok, new_state} -> new_state
      {:error, :no_capacity, new_state} -> buffer_pending(new_state, event)
      {:error, _other, new_state} -> new_state
    end
  end

  defp dispatch_event(%Stc.Event.Completed{task_id: task_id}, %State{} = state) do
    cleanup_task(state, task_id)
  end

  defp dispatch_event(%Stc.Event.Started{}, %State{} = state), do: state

  defp dispatch_event(_unknown, %State{} = state), do: state

  @spec try_schedule_ready(Stc.Event.Ready.t(), State.t()) ::
          {:ok, State.t()} | {:error, :no_capacity | :locked | atom(), State.t()}
  defp try_schedule_ready(%Stc.Event.Ready{} = event, %State{} = state) do
    with {:ok, locked_state} <- try_acquire_lock(event.task_id, state),
         {:ok, agents} <- select_agents_for_event(event, locked_state),
         {:ok, final_state} <- spawn_executor(event, agents, locked_state) do
      {:ok, final_state}
    else
      {:error, :locked} -> {:error, :locked, state}
      {:error, :no_capacity} -> {:error, :no_capacity, state}
      {:error, :failed_to_spawn} -> {:error, :failed_to_spawn, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec buffer_pending(State.t(), Stc.Event.Ready.t()) :: State.t()
  defp buffer_pending(%State{pending_ready: pending} = state, %Stc.Event.Ready{} = event) do
    %State{state | pending_ready: pending ++ [event]}
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
      task_spec: Spec.new(event.module, event.payload),
      agents: agents,
      agent_ids: Enum.map(agents, & &1.id),
      scheduler_id: state.id,
      reply_buffer: state.reply_buffer,
      attempt: 1,
      cluster_id: nil,
      space_id: nil
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
