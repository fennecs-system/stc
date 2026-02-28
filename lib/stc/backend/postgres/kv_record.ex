defmodule Stc.Backend.Postgres.KVRecord do
  @moduledoc """
  Ecto schema for a row in the `stc_kv` table.

  Values are stored as opaque binaries (bytea). Serialisation is the caller's
  responsibility, keeping the backend format-agnostic.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: :updated_at, inserted_at: false]

  schema "stc_kv" do
    field(:value, :binary)

    timestamps()
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
