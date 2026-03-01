defmodule Stc.Task.Policy.Retry do
  @moduledoc """
  A pre built Retry policy for tasks, supporting a custom backoff fn

  ## Backoff

  The `backoff_fn` receives the current attempt number (1- current attempt) and returns the
  delay in milliseconds before the next attempt. Defaults to a constant 1 second - :timer.seconds(1).
  ```
      # Exponential backoff: 1s, 2s, 4s, 8s, …
      %Retry{backoff_fn: fn attempt -> :timer.seconds(Integer.pow(2, attempt - 1)) end}

      # Linear backoff: 500ms, 1000ms, 1500ms, …
      %Retry{backoff_fn: fn attempt -> attempt * 500 end}
  ```
  """

  defstruct max_attempts: 3, backoff_fn: nil, retriable_reasons: :all

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff_fn: (pos_integer() -> pos_integer()) | nil,
          retriable_reasons: [atom()] | :all
        }

  @doc "Gives the backoff delay in ms for the given attempt number. Defaults to 1 second - :timer.second(1)."
  @spec backoff_ms(t(), pos_integer()) :: pos_integer()
  def backoff_ms(%__MODULE__{backoff_fn: nil}, _attempt), do: :timer.seconds(1)
  def backoff_ms(%__MODULE__{backoff_fn: f}, attempt), do: f.(attempt)

  @doc "Returns true if `reason` is retryable under this policy."
  @spec retriable?(t(), term()) :: boolean()
  def retriable?(%__MODULE__{} = policy, reason) do
    case policy.retriable_reasons do
      :all -> true
      reasons -> reason in reasons
    end
  end

  @doc "Returns true if another attempt should be made."
  @spec should_retry?(t(), pos_integer(), term()) :: boolean()
  def should_retry?(policy, attempt, reason) do
    attempt < policy.max_attempts && retriable?(policy, reason)
  end
end
