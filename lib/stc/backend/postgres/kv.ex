defmodule Stc.Backend.Postgres.KV do
  @moduledoc """
  PostgreSQL implementation of `Stc.Backend.KV`.

  ## Storage

  Values are stored as `bytea` in the `stc_kv` table. Serialisation is the caller's
  responsibility (`term_to_binary`, Protobuf, etc.).

  `put/2` is an upsert (`INSERT ... ON CONFLICT DO UPDATE`) so concurrent writers for
  the same key are safe — the last writer wins (LWW).

  ## Configuration

      # config/config.exs
      config :stc, :kv, {Stc.Backend.Postgres.KV, repo: MyApp.Repo}
  """

  @behaviour Stc.Backend.KV

  import Ecto.Query

  alias Stc.Backend.Postgres.KVRecord

  @impl Stc.Backend.KV
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, value) when is_binary(key) and is_binary(value) do
    now = DateTime.utc_now()

    result =
      repo().insert(
        %KVRecord{key: key, value: value},
        on_conflict: [set: [value: value, updated_at: now]],
        conflict_target: :key
      )

    case result do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl Stc.Backend.KV
  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case repo().get(KVRecord, key) do
      %KVRecord{value: value} -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  @impl Stc.Backend.KV
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    repo().delete_all(from(r in KVRecord, where: r.key == ^key))
    :ok
  end

  @impl Stc.Backend.KV
  @spec list_keys() :: {:ok, [String.t()]} | {:error, term()}
  def list_keys do
    keys = repo().all(from(r in KVRecord, select: r.key))
    {:ok, keys}
  rescue
    e -> {:error, e}
  end

  @spec repo() :: module()
  defp repo do
    {_mod, opts} = Application.fetch_env!(:stc, :kv)
    Keyword.fetch!(opts, :repo)
  end
end
