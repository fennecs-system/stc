defmodule Stc.Task.Result do
  @moduledoc """
  Wraps a task's return value with optional metadata.

  `result` holds the plain value returned by the task module. `_meta` is an
  open map for any extra state that may be useful for tracking or debugging
  (e.g. node info, attempt context) without affecting business logic.

  The event - `Stc.Event.Completed` stores timing data for the system.
  """

  @type t :: %__MODULE__{
          result: any(),
          _meta: map()
        }

  defstruct [:result, _meta: %{}]

  @doc "Wraps `value` in a Result with optional metadata."
  @spec to_result(any(), map()) :: t()
  def to_result(value, meta \\ %{}) do
    %__MODULE__{result: value, _meta: meta}
  end
end
