defmodule STC.Task.RetryPolicy do
  @moduledoc """
  Executes a task
  """
  defstruct max_attempts: 3, backoff_ms: 1000, retriable_reasons: :all

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff_ms: pos_integer(),
          retriable_reasons: [atom()] | :all
        }


  def retriable?(%__MODULE__{} = policy, reason) do
    case policy.retriable_reasons do
      :all -> true
      reasons -> reason in reasons
    end
  end

  def should_retry?(policy, attempt, reason) do
    attempt < policy.max_attempts && retriable?(policy, reason)
  end
end
