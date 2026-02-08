defmodule STC.Task do
  @moduledoc """
  a generic task behavior

  Tasks get executed by an agent -

  If the app dies a transactional style clean step is supported

  So we can look at all the stored events. If a task was in procsess, but the app died, and we can reconstruct the
  state based on all the events, and look at what needs to be rolled back.
  """
  alias STC.Task.Spec

  @callback execute(spec :: Spec.t(), context :: map()) ::
              {:ok, result :: any()} | {:started, handle :: any()} | {:error, reason :: any()}

  # rollback semantics
  @callback clean(spec :: Spec.t(), context :: map()) :: :ok | {:error, reason :: any()}

  @callback retriable?(reason :: any()) :: boolean()

  @optional_callbacks retriable?: 1, clean: 2
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

  @doc """
  Default implementation of clean if the task module does not implement it
  """
  def clean(module, spec, context) do
    if function_exported?(module, :clean, 2) do
      module.clean(spec, context)
    else
      :ok
    end
  end

end
