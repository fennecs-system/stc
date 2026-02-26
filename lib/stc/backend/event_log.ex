defmodule Stc.Backend.EventLog do
  @moduledoc """
  Behaviour for an append-only event log backend.

  ## Cursor semantics

  A `cursor` is an opaque, backend-specific value that represents a position in the
  log. Callers obtain a starting cursor from `origin/0` and advance it by passing the
  cursor returned from `fetch/2` into the next call. Cursors are monotonically
  increasing within a backend instance.

  ## Distributed-systems guarantees (CP)

  All `try_lock/3` implementations **must** be atomic. The system is CP: during a
  partition, consumers stall rather than risk double-scheduling. No two concurrent
  callers may both receive `{:ok, lock}` for the same `task_id`.

  ## Future: lenses and replayability

  Because the cursor is an opaque log position, full replay is always possible by
  passing `origin/0` into `fetch/2`. Lenses (bi-directional version transforms) can
  be applied during replay without changes to this interface.
  """

  @typedoc """
  Opaque cursor into the event log.

  Backend-specific: an integer sequence for `Memory`, a bigint row ID for `Postgres`,
  a RocksDB sequence number for a RocksDB backend, etc. Callers must treat this as
  opaque and never construct or inspect it.
  """
  @type cursor :: term()

  @typedoc "Options accepted by `fetch/2`."
  @type fetch_opt ::
          {:types, [module()]}
          | {:limit, pos_integer()}

  @doc """
  Returns the cursor position before any events.

  Passing this into `fetch/2` will return all events ever appended.
  """
  @callback origin() :: cursor()

  @doc """
  Appends an event to the log.

  Returns `{:ok, new_cursor}` where `new_cursor` points to the position of the
  newly appended event. Implementations must assign a monotonically increasing
  sequence to each event.
  """
  @callback append(event :: struct()) :: {:ok, cursor()} | {:error, term()}

  @doc """
  Fetches events strictly after `cursor`.

  ## Options

    - `:types` — list of struct modules to include; defaults to all types.
    - `:limit` — maximum number of events to return; defaults to `100`.

  Returns `{:ok, events, new_cursor}` where `new_cursor` is the position after the
  last returned event. When no new events exist, returns `{:ok, [], same_cursor}`.
  """
  @callback fetch(cursor(), [fetch_opt()]) :: {:ok, [struct()], cursor()}

  @doc """
  Attempts to atomically acquire an exclusive lock for `task_id`.

  Semantics:
    - If `task_id` is unlocked: acquires with `{lock, caller_id}`, returns `{:ok, lock}`.
    - If `task_id` is locked by the **same** `caller_id`: re-entrant, returns
      `{:ok, existing_lock}`.
    - If `task_id` is locked by a **different** caller: returns `{:error, :locked}`.

  Implementations must ensure this operation is atomic (GenServer serialisation
  for Memory, `INSERT ... ON CONFLICT DO NOTHING` + transaction for Postgres, etc.).
  """
  @callback try_lock(task_id :: String.t(), lock :: term(), caller_id :: term()) ::
              {:ok, term()} | {:error, :locked}

  @doc """
  Releases the lock for `task_id`, if held with the given `lock`.

  Returns `:ok` on success, `{:error, :not_owner}` if `lock` does not match the
  currently held lock.
  """
  @callback release_lock(task_id :: String.t(), lock :: term()) ::
              :ok | {:error, :not_owner | term()}
end
