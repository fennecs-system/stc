defmodule Stc.Event.Store do
  @moduledoc """
  Facade over the configured `Stc.Backend.EventLog` backend.

  All callers interact with this module; the underlying backend is selected at
  application config time and is never referenced directly outside of this file and
  `Stc.Backend`.

  See `Stc.Backend.EventLog` for the full contract documentation.
  """

  require Logger

  @doc "Returns the cursor before all events (enables full replay)."
  @spec origin() :: Stc.Backend.EventLog.cursor()
  def origin, do: backend().origin()

  @doc "Appends an event to the log."
  @spec append(struct()) :: {:ok, Stc.Backend.EventLog.cursor()} | {:error, term()}
  def append(event) do
    Logger.info("Appending event: #{inspect(event)}")
    backend().append(event)
  end

  @doc """
  Fetches events strictly after `cursor`.

  See `Stc.Backend.EventLog.fetch/2` for option docs.
  """
  @spec fetch(Stc.Backend.EventLog.cursor(), [Stc.Backend.EventLog.fetch_opt()]) ::
          {:ok, [struct()], Stc.Backend.EventLog.cursor()}
  def fetch(cursor, opts \\ []), do: backend().fetch(cursor, opts)

  @doc "Atomically acquires a lock for `task_id`."
  @spec try_lock(String.t(), term(), term()) :: {:ok, term()} | {:error, :locked}
  def try_lock(task_id, lock, caller_id), do: backend().try_lock(task_id, lock, caller_id)

  @doc "Releases the lock for `task_id`."
  @spec release_lock(String.t(), term()) :: :ok | {:error, term()}
  def release_lock(task_id, lock), do: backend().release_lock(task_id, lock)

  @doc "Releases all locks held by `caller_id` (stale lock cleanup on boot)."
  @spec release_locks_by_caller(term()) :: :ok
  def release_locks_by_caller(caller_id), do: backend().release_locks_by_caller(caller_id)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec backend() :: module()
  defp backend, do: Stc.Backend.event_log()
end
