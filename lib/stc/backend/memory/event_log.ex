defmodule Stc.Backend.Memory.EventLog.State do
  @moduledoc false

  @type lock :: {lock_id :: term(), caller_id :: term()}

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          events: %{non_neg_integer() => struct()},
          locks: %{String.t() => lock()}
        }

  defstruct seq: 0, events: %{}, locks: %{}
end

defmodule Stc.Backend.Memory.EventLog do
  @moduledoc """
  In-memory implementation of `Stc.Backend.EventLog`.

  ## Cursor

  The cursor is a non-negative integer sequence number. Event 1 is the first ever
  appended; `origin/0` returns `0` (before all events). Fetching with cursor `n`
  returns all events with sequence > n.

  ## Atomicity

  All operations are serialised through a single GenServer process, so locking is
  trivially atomic — no CAS or transaction overhead required.

  ## Usage

  Start once in your supervision tree (typically via `Stc.Backend.Supervisor`):

      children = [Stc.Backend.Memory.EventLog]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  @behaviour Stc.Backend.EventLog

  use GenServer

  alias Stc.Backend.Memory.EventLog.State
  require Logger

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %State{}, name: name)
  end

  @impl Stc.Backend.EventLog
  @spec origin() :: non_neg_integer()
  def origin, do: 0

  @impl Stc.Backend.EventLog
  @spec append(struct()) :: {:ok, pos_integer()} | {:error, term()}
  def append(event) do
    GenServer.call(__MODULE__, {:append, event})
  end

  @impl Stc.Backend.EventLog
  @spec fetch(non_neg_integer(), [Stc.Backend.EventLog.fetch_opt()]) ::
          {:ok, [struct()], non_neg_integer()}
  def fetch(cursor, opts \\ []) do
    GenServer.call(__MODULE__, {:fetch, cursor, opts})
  end

  @impl Stc.Backend.EventLog
  @spec try_lock(String.t(), term(), term()) :: {:ok, term()} | {:error, :locked}
  def try_lock(task_id, lock, caller_id) do
    GenServer.call(__MODULE__, {:try_lock, task_id, lock, caller_id})
  end

  @impl Stc.Backend.EventLog
  @spec release_lock(String.t(), term()) :: :ok | {:error, :not_owner}
  def release_lock(task_id, lock) do
    GenServer.call(__MODULE__, {:release_lock, task_id, lock})
  end

  @impl Stc.Backend.EventLog
  @spec release_locks_by_caller(term()) :: :ok
  def release_locks_by_caller(caller_id) do
    GenServer.call(__MODULE__, {:release_locks_by_caller, caller_id})
  end

  @impl true
  def init(%State{} = state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:append, event}, _from, %State{seq: seq, events: events} = state) do
    new_seq = seq + 1
    new_state = %State{state | seq: new_seq, events: Map.put(events, new_seq, event)}
    {:reply, {:ok, new_seq}, new_state}
  end

  @impl true
  def handle_call({:fetch, cursor, opts}, _from, %State{events: events} = state) do
    types = Keyword.get(opts, :types, :all)
    limit = Keyword.get(opts, :limit, 100)
    task_id = Keyword.get(opts, :task_id, :any)
    workflow_id = Keyword.get(opts, :workflow_id, :any)

    # Sort integer keys first so downstream filters can terminate early via Enum.take,
    # avoiding materialising the entire filtered set before applying the limit.
    result =
      events
      |> Map.keys()
      |> Enum.filter(fn seq -> seq > cursor end)
      |> Enum.sort()
      |> Stream.map(fn seq -> {seq, Map.fetch!(events, seq)} end)
      |> Stream.filter(fn {_seq, event} -> type_matches?(event, types) end)
      |> Stream.filter(fn {_seq, event} -> field_matches?(event, :task_id, task_id) end)
      |> Stream.filter(fn {_seq, event} -> field_matches?(event, :workflow_id, workflow_id) end)
      |> Enum.take(limit)

    case result do
      [] ->
        {:reply, {:ok, [], cursor}, state}

      entries ->
        fetched = Enum.map(entries, fn {_seq, event} -> event end)
        new_cursor = entries |> List.last() |> elem(0)
        {:reply, {:ok, fetched, new_cursor}, state}
    end
  end

  @impl true
  def handle_call(
        {:try_lock, task_id, lock, caller_id},
        _from,
        %State{locks: locks} = state
      ) do
    case Map.get(locks, task_id) do
      nil ->
        new_state = %State{state | locks: Map.put(locks, task_id, {lock, caller_id})}
        {:reply, {:ok, lock}, new_state}

      {existing_lock, ^caller_id} ->
        # Re-entrant: same caller already holds the lock.
        {:reply, {:ok, existing_lock}, state}

      {_other_lock, _other_caller} ->
        {:reply, {:error, :locked}, state}
    end
  end

  @impl true
  def handle_call({:release_lock, task_id, lock}, _from, %State{locks: locks} = state) do
    case Map.get(locks, task_id) do
      {^lock, _caller_id} ->
        {:reply, :ok, %State{state | locks: Map.delete(locks, task_id)}}

      nil ->
        # Already released; treat as success (idempotent).
        {:reply, :ok, state}

      {_other_lock, _other_caller} ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_call({:release_locks_by_caller, caller_id}, _from, %State{locks: locks} = state) do
    new_locks = Map.reject(locks, fn {_task_id, {_lock, cid}} -> cid == caller_id end)
    {:reply, :ok, %State{state | locks: new_locks}}
  end

  @spec type_matches?(struct(), :all | [module()]) :: boolean()
  defp type_matches?(_event, :all), do: true
  defp type_matches?(event, types), do: Enum.any?(types, &is_struct(event, &1))

  @spec field_matches?(struct(), atom(), :any | term()) :: boolean()
  defp field_matches?(_event, _field, :any), do: true
  defp field_matches?(event, field, value), do: Map.get(event, field) == value
end
