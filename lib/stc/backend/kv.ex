defmodule Stc.Backend.KV do
  @moduledoc """
  Behaviour for a key-value store backend.

  Values are opaque binaries; serialisation is the caller's responsibility.
  Keeping the backend format-agnostic allows callers to use `:erlang.term_to_binary`,
  Protobuf, or any other encoding without touching the backend.

  This is a **CP** store: put/get operations are linearisable. No eventual-consistency
  window exists between a successful `put/2` and a subsequent `get/1` from any node.
  """

  @doc """
  Persists `value` under `key`, overwriting any existing value.
  """
  @callback put(key :: String.t(), value :: binary()) :: :ok | {:error, term()}

  @doc """
  Retrieves the value stored under `key`.

  Returns `{:error, :not_found}` when no value has been stored for `key`.
  """
  @callback get(key :: String.t()) :: {:ok, binary()} | {:error, :not_found}

  @doc """
  Removes the entry for `key`. Idempotent: returns `:ok` even if the key did not exist.
  """
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
end
