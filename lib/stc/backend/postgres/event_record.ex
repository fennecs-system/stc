defmodule Stc.Backend.Postgres.EventRecord do
  @moduledoc """
  Ecto schema for a row in the `stc_events` table.

  The `payload` column stores the full serialised event struct as a binary (bytea).
  The `type`, `task_id`, and `workflow_id` columns are extracted to top-level columns
  to allow efficient filtering in `fetch/2` without deserialising the payload.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: false]

  schema "stc_events" do
    field(:type, :string)
    field(:task_id, :string)
    field(:workflow_id, :string)
    field(:payload, :binary)

    timestamps()
  end
end
