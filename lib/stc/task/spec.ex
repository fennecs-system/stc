defmodule Stc.Task.Spec do
  @moduledoc """
  Generic specification for a task
  """
  alias Stc.Task.RetryPolicy

  defstruct [
    :module,
    :payload,
    :retry_policy,
    :timeout_ms,
    :startup_timeout_ms
  ]

  @type t :: %__MODULE__{
          module: module(),
          payload: map(),
          retry_policy: RetryPolicy.t(),
          startup_timeout_ms: pos_integer() | nil,
          timeout_ms: pos_integer() | nil
        }

  @spec new(module(), map(), keyword()) :: t()
  def new(module, payload, opts \\ []) do
    retry_policy = Keyword.get(opts, :retry_policy, %RetryPolicy{})
    timeout_ms = Keyword.get(opts, :timeout_ms, :timer.hours(1))
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, :timer.hours(1))

    %__MODULE__{
      module: module,
      payload: payload,
      retry_policy: retry_policy,
      timeout_ms: timeout_ms,
      startup_timeout_ms: startup_timeout_ms
    }
  end
end
