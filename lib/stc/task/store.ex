defmodule Stc.Task.Store do
  @moduledoc """
  Content-addressed task result cache.

  When a task is decorated with `store: true` in `Program.run/4`, its result is
  keyed by the SHA-256 digest of `{module, payload}` encoded as an Erlang term.
  Subsequent runs of the same task module with identical payload skip execution
  entirely and return the cached result.

  Keys live under `"stc:task_store:<sha256_hex>"` in the configured KV backend.
  """

  alias Stc.Backend

  @prefix "stc:task_store:"

  @doc "Returns the SHA-256 hex digest of `{module, payload}`."
  @spec content_hash(module(), map()) :: String.t()
  def content_hash(module, payload) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({module, payload}))
    |> Base.encode16(case: :lower)
  end

  @doc "Retrieves a cached result. Returns `{:ok, result}` or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, term()} | {:error, :not_found}
  def get(hash) do
    case Backend.kv().get(@prefix <> hash) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary, [:safe])}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Persists `result` under `hash`."
  @spec put(String.t(), term()) :: :ok | {:error, term()}
  def put(hash, result) do
    Backend.kv().put(@prefix <> hash, :erlang.term_to_binary(result))
  end
end
