defmodule STC.Event.Store do
  @moduledoc """
  A simple event store for STC events. Stores events in memory for now.
  """
  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def try_lock(task_id, lock, caller_id) do
    GenServer.call(__MODULE__, {:try_lock, task_id, lock, caller_id})
  end

  def init(state) do
    {:ok, %{events: [], locks: %{}, event_to_lock: %{}, subscribers: []}}
  end

  def append(event) do
    Logger.info("Appending event: #{inspect(event)}")
    GenServer.call(__MODULE__, {:append, event})
  end

  def subscribe(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid}, 10_000)
  end

  def find_ready_events() do
    # find all ready events to be scheduled
    GenServer.call(__MODULE__, :find_ready_events)
  end

  def get_events(filters) do
    GenServer.call(__MODULE__, {:get_events, filters})
  end

  def handle_call({:append, event}, _from, state) do
    new_state = Map.update(state, :events, [event], fn events -> [event | events] end)

    # notify subscribers
    Enum.each(Map.get(state, :subscribers, []), fn pid ->
      Logger.info("Notifying subscriber #{inspect(pid)} of new event")
      send(pid, event)
    end)

    {:reply, :ok, new_state}
  end

  def handle_call(:find_ready_events, _from, state) do
    events =
      Map.get(state, :events, [])
      |> Enum.filter(fn event -> is_struct(event, STC.Event.Ready) end)

    # filter events that have already been scheduled - so events that dont have a lock yet
    events =
      Enum.filter(events, fn event ->
        not Map.has_key?(Map.get(state, :event_to_lock, %{}), event)
      end)

    {:reply, events, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    # subscribe the pid to event notifications
    new_state = Map.update(state, :subscribers, [pid], fn subs -> [pid | subs] end)
    {:reply, :ok, new_state}
  end

  def handle_call({:try_lock, task_id, lock, caller_id}, _from, state) do
    locks = Map.get(state, :locks, %{})

    case Map.get(locks, task_id) do
      nil ->
        # not locked yet, acquire lock
        # lock every event with this task_id
        locked_events =
          Enum.filter(Map.get(state, :events, []), fn event ->
            case event do
              %{task_id: ^task_id} -> true
              _ -> false
            end
          end)

        new_locks = Map.put(locks, task_id, {lock, caller_id, locked_events})

        event_to_locks =
          Enum.reduce(locked_events, Map.get(state, :event_to_lock, %{}), fn event, acc ->
            Map.put(acc, event, lock)
          end)

        # now lock every event with this task_id
        new_state =
          Map.put(state, :locks, new_locks)
          |> Map.put(:event_to_lock, event_to_locks)

        {:reply, {:ok, lock}, new_state}

      {existing_lock, existing_caller_id, _} ->
        if existing_caller_id == caller_id do
          # already locked by the same caller, allow re-entrance
          {:reply, {:ok, existing_lock}, state}
        else
          # locked by someone else
          {:reply, {:error, :locked}, state}
        end
    end
  end

  def handle_call({:get_events, filters}, _from, state) do
    events =
      Map.get(state, :events, [])
      |> Enum.filter(fn event ->
        Enum.all?(filters, fn {key, value} -> Map.get(event, key) == value end)
      end)

    # check that the event isn't locked
    events =
      Enum.filter(events, fn event ->
        not Map.has_key?(Map.get(state, :event_to_lock, %{}), event)
      end)

    {:reply, events, state}
  end
end
