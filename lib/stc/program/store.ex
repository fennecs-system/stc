defmodule Stc.Program.Store do
  @moduledoc """
  Facade over the configured `Stc.Backend.KV` backend, providing typed
  put/get operations for program continuation state.

  Values are serialised with `:erlang.term_to_binary/1` (allowing arbitrary Elixir
  terms including closures and continuations) and deserialised with
  `:erlang.binary_to_term/2` using the `:safe` flag.

  The `workflow_id` is always a `String.t()` key. The stored value is the current
  free-monad program tree for that workflow.
  """

  @doc "Persists `program` under `workflow_id`, overwriting any prior state."
  @spec put(String.t(), term()) :: :ok | {:error, term()}
  def put(workflow_id, program) when is_binary(workflow_id) do
    backend().put(workflow_id, :erlang.term_to_binary(program))
  end

  @doc """
  Retrieves the program stored under `workflow_id`.

  Returns `{:error, :not_found}` when no program has been stored for that workflow.
  """
  @spec get(String.t()) :: {:ok, term()} | {:error, :not_found}
  def get(workflow_id) when is_binary(workflow_id) do
    case backend().get(workflow_id) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary, [:safe])}
      {:error, :not_found} = err -> err
    end
  end

  @doc "Removes the program state for `workflow_id`."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(workflow_id) when is_binary(workflow_id) do
    backend().delete(workflow_id)
  end

  @doc "Returns all workflow IDs that currently have stored program state."
  @spec list_workflow_ids() :: {:ok, [String.t()]} | {:error, term()}
  def list_workflow_ids do
    backend().list_keys()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec backend() :: module()
  defp backend, do: Stc.Backend.kv()
end
