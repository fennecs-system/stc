defmodule STC.Task do
  @moduledoc """
  a generic task behavior
  """

  @callback execute(spec :: map(), context :: map()) ::
              {:ok, result :: any()} | {:started, handle :: any()} | {:error, reason :: any()}

  @callback retriable?(reason :: any()) :: boolean()

  @optional_callbacks retriable?: 1

  @doc """
  Default implementation of is_retriable? if the task module does not implement it
  """
  def retriable?(module, reason) do
    if function_exported?(module, :retriable?, 1) do
      module.retriable?(reason)
    else
      false
    end
  end
end
