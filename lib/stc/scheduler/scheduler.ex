defmodule STC.Scheduler.State do
  defstruct [
    :id,
    # what level does this scheduler operate at? local? space? cluster?
    :level,
    :agent_pool,
    # agents that might be temporarily inactive - eg small timeout,
    :stale_agent_pool,
    :algorithm,
    # agent_id => [task_id]
    :agent_tasks,
    :task_locks,
    # task_id => {pid, os pid, systemd unit etc}
    :active_tasks,
    :event_loop_ref,
    # AgentReplyBuffer.t()
    :reply_buffer
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          level: atom(),
          agent_pool: list(),
          stale_agent_pool: list(),
          algorithm: module(),
          agent_tasks: map(),
          task_locks: map(),
          active_tasks: map(),
          event_loop_ref: reference() | nil,
          reply_buffer: pid()
        }
end

defmodule STC.Scheduler do
  @moduledoc """
  A generic scheduler for STC tasks
  """
  use GenServer
  require Logger
  alias STC.Event.Store
  alias STC.Scheduler.Executor
  alias STC.Spec
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
      agent_tasks: %{},
      task_locks: %{},
      active_tasks: %{},
      event_loop_ref: nil,
      reply_buffer: pid
    }

    {:ok, schedule_event_loop(state)}
  end

  def handle_info(:event_loop, %State{} = state) do
    state =
      state
      |> refresh_agent_pool()
      |> reconcile_stale_agents()

    ready_events = poll_ready_events(state)
    # return events
    # pause_events = poll_pause_events(state)

    # resume_events = poll_resume_events(state)

    # stop_events = poll_stop_events(state)

    # events = ready_events ++ pause_events ++ resume_events ++ stop_events

    events = ready_events

    events = schedule_event_order(events, state)

    _ =
      Enum.reduce(events, state, fn event, acc ->
        # Logger.info("scheduling task #{event.task_id} in scheduler #{state.id}")
        schedule_task(event, acc)
      end)

    Logger.debug("Scheduler #{state.id} event loop completed.")

    {:noreply, schedule_event_loop(state)}
  end

  def schedule_event_loop(%State{} = state) do
    if not is_nil(state.event_loop_ref), do: Process.cancel_timer(state.event_loop_ref)
    ref = Process.send_after(self(), :event_loop, :timer.seconds(1))
    %{state | event_loop_ref: ref}
  end

  def schedule_task(event, %State{} = state) do
    with {:ok, state} <- try_acquire_lock(event.task_id, state),
         {:ok, agents} <- select_agents_for_event(event, state),
         {:ok, state} <- spawn_executor(event, agents, state) do
      state
    else
      {:error, :locked} ->
        state

      {:error, :no_capacity} ->
        state

      {:error, _reason} ->
        state
    end
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

  def schedule_event_order(events, state) do
    # currently no special ordering
    state.algorithm.schedule_event_order(events, state)
  end

  def select_agents_for_event(event, state) do
    available =
      state.agent_pool
      |> Enum.filter(fn agent ->
        agent_matches_requirements?(agent, event) &&
          (agent_is_free?(agent, state) || can_oversubscribe?(agent, event, state))
      end)

    state.algorithm.select_agents_for_event(event, available, state)
  end

  def spawn_executor(event, agents, state) do
    # spawn executor process for task on selected agents
    # track active tasks
    {:ok, pid} =
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
      })

    state = %{state | active_tasks: Map.put(state.active_tasks, event.task_id, pid)}

    {:ok, state}
  end

  defp agent_matches_requirements?(_agent, _event) do
    # check agent type, affinity, etc
    true
  end

  defp agent_is_free?(agent, state) do
    Map.get(state.agent_tasks, agent.id, [])
    |> Enum.empty?()
  end

  defp can_oversubscribe?(_agent, _event, _state) do
    # check if agent allows oversubscription and if task affinity allows it
    false
  end

  def refresh_agent_pool(state) do
    new_agent_pool = state.algorithm.refresh_agent_pool(state)
    %{state | agent_pool: new_agent_pool}
  end

  def reconcile_stale_agents(state) do
    state
  end

  def poll_ready_events(_state) do
    # poll event store for tasks ready to be scheduled

    events = Store.find_ready_events()
    # Logger.info("Schedueler found #{length(events)} ready events: #{inspect(events)}")
    events
  end

  def recover_state_from_events(state, _event) do
    state
  end

  def recover_active_tasks(state) do
    state
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
end
