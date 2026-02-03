defmodule STC.Spec do
  @moduledoc """
  Generic specification for a task
  """
  alias STC.RetryPolicy

  @type t :: %__MODULE__{
          module: module(),
          payload: map(),
          retry_policy: STC.RetryPolicy.t(),
          timeout_ms: pos_integer()
        }

  defstruct [
    :module,
    :payload,
    retry_policy: %RetryPolicy{},
    timeout_ms: 30_000
  ]

  def new(module, payload, opts \\ []) do
    retry_policy = Keyword.get(opts, :retry_policy, %RetryPolicy{})
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    %__MODULE__{
      module: module,
      payload: payload,
      retry_policy: retry_policy,
      timeout_ms: timeout_ms
    }
  end
end
