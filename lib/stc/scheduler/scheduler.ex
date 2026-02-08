defmodule STC.Scheduler do
  @moduledoc """
  A generic scheduler for STC tasks
  """
  use GenServer
  require Logger

  alias STC.Event.Store
  alias STC.Scheduler.Executor
  alias STC.Task.Spec
  # alias STC.Scheduler.Algorithm
  alias STC.ReplyBuffer

  alias STC.Scheduler.State

  def via(id) do
    {:via, Horde.Registry, {STC.SchedulerRegistry, "scheduler_#{id}"}}
  end

  # start with horde probs
  def start_link(opts) do
    id = Keyword.get(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id)

    {:ok, pid} = ReplyBuffer.start_link(scheduler_id: id)

    state = %State{
      id: id,
      level: Keyword.get(opts, :level),
      agent_pool: [],
      stale_agent_pool: [],
      algorithm: Keyword.get(opts, :algorithm),
      # map of agent id => tasks
      agent_tasks: %{},
      task_locks: %{},
      # map of task id => executor
      active_tasks: %{},
      event_loop_ref: nil,
      reply_buffer: pid
    }

    {:ok, schedule_event_loop(state)}
  end

  @impl true
  def handle_info(:recover, state) do
    events = Store.get_events(scheduler_id: state.scheduler_id)

    state =
      state
      |> recover_state_from_events(events)
      |> recover_active_tasks()

    {:noreply, schedule_event_loop(state)}
  end

  def handle_info(:event_loop, %State{} = state) do
    %State{} =
      state =
      state
      |> refresh_agent_pool()
      |> reconcile_stale_agents()
      |> process_agent_buffer()

    ready_events = poll_ready_events(state)
    # return events
    # pause_events = poll_pause_events(state)

    # started events

    # resume_events = poll_resume_events(state)

    completed_events = poll_completed_events(state)

    started_events = poll_started_events(state)

    # events = ready_events ++ pause_events ++ resume_events ++ stop_events

    events = ready_events ++ completed_events ++ started_events

    state =
      events
      |> schedule_event_order(state)
      |> Enum.reduce(state, fn event, acc ->
        # Logger.info("scheduling task #{event.task_id} in scheduler #{state.id}")
        schedule_task(event, acc)
      end)

    Logger.debug("Scheduler #{state.id} event loop completed.")

    {:noreply, schedule_event_loop(state)}
  rescue
    err ->
      Logger.error(
        "Rescued error in scheduler #{state.id} event loop: #{Exception.format(:error, err, __STACKTRACE__)}"
      )

      {:noreply, schedule_event_loop(state)}
  catch
    kind, payload ->
      Logger.error(
        "Caught error in scheduler #{state.id} event loop: #{Exception.format(kind, payload, __STACKTRACE__)}"
      )

      {:noreply, schedule_event_loop(state)}
  end

  def schedule_event_loop(%State{} = state) do
    if not is_nil(state.event_loop_ref), do: Process.cancel_timer(state.event_loop_ref)
    ref = Process.send_after(self(), :event_loop, :timer.seconds(1))
    %{state | event_loop_ref: ref}
  end

  # ready events get scheduled
  def schedule_task(%STC.Event.Ready{} = event, %State{} = state) do
    with {:ok, state} <- try_acquire_lock(event.task_id, state),
         {:ok, [_ | _] = agents} <- select_agents_for_event(event, state),
         {:ok, state} <- spawn_executor(event, agents, state) do
      state
    else
      {:error, :locked} ->
        state

      {:error, :no_capacity} ->
        state

      {:error, :failed_to_spawn} ->
        # cleanup
        state

      {:error, _reason} ->
        state
    end
  end

  # completed events can be removed from the state
  def schedule_task(%STC.Event.Completed{task_id: _task_id}, %State{} = state) do
    state
  end

  # started - can tick event
  def schedule_task(%STC.Event.Started{task_id: _task_id}, %State{} = state) do
    state
  end

  # failed events can be removed from the state
  def schedule_task(_, %State{} = state) do
    state
  end

  def try_acquire_lock(task_id, state) do
    # try to acquire lock via Event.Store - compare and swap
    lock = :erlang.unique_integer()

    case Store.try_lock(task_id, lock, state.id) do
      {:ok, ^lock} ->
        {:ok, put_in(state.task_locks[task_id], lock)}

      {:ok, _other_lock} ->
        {:error, :locked}

      {:error, :locked} ->
        {:error, :locked}
    end
  end

  def schedule_event_order(events, state), do: state.algorithm.schedule_event_order(events, state)

  def process_agent_buffer(state), do: state.algorithm.process_agent_buffer(state)

  def select_agents_for_event(event, %State{} = state) do
    case state.agent_pool
         |> Enum.filter(fn agent ->
           agent_matches_requirements?(agent, event) and
             (agent_is_free?(agent, state) or can_oversubscribe?(agent, event, state))
         end) do
      [] ->
        Logger.warning("No capacity for event #{inspect(event)}")
        {:error, :no_capacity}

      [_ | _] = available ->
        state.algorithm.select_agents_for_event(event, available, state)
    end
  end

  def spawn_executor(event, agents, state) do
    # spawn executor process for task on selected agents
    # track active tasks
    with {:ok, pid} <-
           Executor.start_link(%{
             workflow_id: event.workflow_id,
             task_id: event.task_id,
             task_spec: Spec.new(event.module, event.payload),
             agents: agents,
             agent_ids: Enum.map(agents, fn a -> a.id end),
             scheduler_id: state.id,
             reply_buffer: state.reply_buffer,
             attempt: 1,
             cluster_id: nil,
             space_id: nil
           }),
         state <- %{state | active_tasks: Map.put(state.active_tasks, event.task_id, pid)},
         # for each agent, add it to the agent ids
         agent_tasks <-
           Enum.reduce(
             agents,
             state.agent_tasks,
             fn agent, tasks ->
               Map.update(tasks, agent.id, [event.task_id], fn ids -> [event.task_id | ids] end)
             end
           )
           |> dbg(),
         state <- %{state | agent_tasks: agent_tasks} do
      {:ok, state}
    else
      _error ->
        {:error, :failed_to_spawn}
    end
  end

  defp agent_matches_requirements?(_agent, _event) do
    # check agent type, affinity, etc
    true
  end

  defp agent_is_free?(%{id: id} = _agent, %State{} = state) do
    state.agent_tasks
    |> Map.get(id, [])
    |> Enum.empty?()
  end

  defp can_oversubscribe?(_agent, _event, _state) do
    # check if agent allows oversubscription and if task affinity allows it
    false
  end

  def refresh_agent_pool(state), do: state.algorithm.refresh_agent_pool(state)

  def reconcile_stale_agents(state) do
    state
  end

  def poll_ready_events(_state) do
    # poll event store for tasks ready to be scheduled
    events = Store.filter_events(STC.Event.Ready)
    events
  end

  def poll_started_events(_state) do
    # poll event store for tasks ready to be scheduled
    events = Store.filter_events(STC.Event.Started)
    events
  end

  def poll_completed_events(_state) do
    events = Store.filter_events(STC.Event.Completed)
    events
  end

  def recover_state_from_events(state, _event) do
    state
  end

  def recover_active_tasks(state) do
    state
  end

  # remove from all state
  def cleanup(%State{active_tasks: active_tasks} = state, task_id)
      when is_map_key(active_tasks, task_id) do
    # shut down the executor
    exe_pid = Map.get(active_tasks, task_id)

    GenServer.stop(exe_pid)

    # cleanup active_tasks

    active_tasks = Map.delete(active_tasks, task_id)

    # remove out of any agents

    {:ok, :done}
  end
end
