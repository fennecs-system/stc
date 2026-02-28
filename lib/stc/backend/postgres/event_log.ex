defmodule Stc.Backend.Postgres.EventLog do
  @moduledoc """
  PostgreSQL implementation of `Stc.Backend.EventLog`.

  ## Cursor

  The cursor is the bigint `id` of the last consumed `stc_events` row (auto-increment
  primary key). `origin/0` returns `0`. Fetching with cursor `n` is a simple
  `WHERE id > n ORDER BY id LIMIT limit` — no full table scan, backed by the PK index.

  ## Lock atomicity (CP guarantee)

  `try_lock/3` runs inside a single database transaction using an
  `INSERT ... ON CONFLICT DO NOTHING` followed by a `SELECT` to determine the winner.
  Both statements execute within the same serialisable transaction so no other caller
  can interleave between them. This makes the system CP: a partitioned scheduler node
  that cannot reach Postgres will stall rather than double-schedule.

  ## Configuration

      # config/config.exs
      config :stc, :event_log, {Stc.Backend.Postgres.EventLog, repo: MyApp.Repo}

  ## Payload encoding

  Events are encoded with `:erlang.term_to_binary/1` and stored as `bytea`. The
  `type`, `task_id`, and `workflow_id` fields are additionally stored in dedicated
  columns for cheap server-side filtering.
  """

  @behaviour Stc.Backend.EventLog

  import Ecto.Query

  alias Stc.Backend.Postgres.EventRecord

  @type cursor :: non_neg_integer()

  @impl Stc.Backend.EventLog
  @spec origin() :: 0
  def origin, do: 0

  @impl Stc.Backend.EventLog
  @spec append(struct()) :: {:ok, pos_integer()} | {:error, term()}
  def append(event) do
    record = %EventRecord{
      type: event.__struct__ |> Atom.to_string(),
      task_id: Map.get(event, :task_id),
      workflow_id: Map.get(event, :workflow_id),
      payload: :erlang.term_to_binary(event)
    }

    case repo().insert(record) do
      {:ok, %EventRecord{id: id}} -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  @impl Stc.Backend.EventLog
  @spec fetch(non_neg_integer(), [Stc.Backend.EventLog.fetch_opt()]) ::
          {:ok, [struct()], non_neg_integer()}
  def fetch(cursor, opts \\ []) do
    types = Keyword.get(opts, :types, :all)
    limit = Keyword.get(opts, :limit, 100)
    task_id = Keyword.get(opts, :task_id, :any)
    workflow_id = Keyword.get(opts, :workflow_id, :any)

    records =
      EventRecord
      |> where([e], e.id > ^cursor)
      |> apply_type_filter(types)
      |> apply_field_filter(:task_id, task_id)
      |> apply_field_filter(:workflow_id, workflow_id)
      |> order_by([e], asc: e.id)
      |> limit(^limit)
      |> repo().all()

    case records do
      [] ->
        {:ok, [], cursor}

      [_ | _] ->
        events = Enum.map(records, &deserialise_record/1)
        new_cursor = List.last(records).id
        {:ok, events, new_cursor}
    end
  end

  @impl Stc.Backend.EventLog
  @spec try_lock(String.t(), term(), term()) :: {:ok, term()} | {:error, :locked}
  def try_lock(task_id, lock, caller_id) do
    lock_str = inspect(lock)
    caller_str = inspect(caller_id)
    now = DateTime.utc_now()

    result =
      repo().transaction(fn repo ->
        repo.query!(
          """
          INSERT INTO stc_locks (task_id, lock_id, caller_id, acquired_at)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (task_id) DO NOTHING
          """,
          [task_id, lock_str, caller_str, now]
        )

        repo.query!(
          "SELECT lock_id, caller_id FROM stc_locks WHERE task_id = $1",
          [task_id]
        )
      end)

    case result do
      {:ok, %{rows: [[^lock_str, _any_caller]]}} -> {:ok, lock}
      {:ok, %{rows: [[_other_lock, ^caller_str]]}} -> {:ok, lock}
      {:ok, %{rows: [[_other_lock, _other_caller]]}} -> {:error, :locked}
      {:error, _} -> {:error, :locked}
    end
  end

  @impl Stc.Backend.EventLog
  @spec release_lock(String.t(), term()) :: :ok | {:error, :not_owner}
  def release_lock(task_id, lock) do
    lock_str = inspect(lock)

    {count, _} =
      repo().delete_all(
        from(l in "stc_locks",
          where: l.task_id == ^task_id and l.lock_id == ^lock_str
        )
      )

    if count > 0, do: :ok, else: {:error, :not_owner}
  end

  @spec repo() :: module()
  defp repo do
    {_mod, opts} = Application.fetch_env!(:stc, :event_log)
    Keyword.fetch!(opts, :repo)
  end

  @impl Stc.Backend.EventLog
  @spec release_locks_by_caller(term()) :: :ok
  def release_locks_by_caller(caller_id) do
    caller_str = inspect(caller_id)
    repo().delete_all(from(l in "stc_locks", where: l.caller_id == ^caller_str))
    :ok
  end

  @spec apply_type_filter(Ecto.Query.t(), :all | [module()]) :: Ecto.Query.t()
  defp apply_type_filter(query, :all), do: query

  defp apply_type_filter(query, types) do
    type_strings = Enum.map(types, &Atom.to_string/1)
    where(query, [e], e.type in ^type_strings)
  end

  @spec apply_field_filter(Ecto.Query.t(), atom(), :any | term()) :: Ecto.Query.t()
  defp apply_field_filter(query, _field, :any), do: query

  defp apply_field_filter(query, :task_id, value),
    do: where(query, [e], e.task_id == ^value)

  defp apply_field_filter(query, :workflow_id, value),
    do: where(query, [e], e.workflow_id == ^value)

  @spec deserialise_record(EventRecord.t()) :: struct()
  defp deserialise_record(%EventRecord{payload: payload}) do
    :erlang.binary_to_term(payload, [:safe])
  end
end
