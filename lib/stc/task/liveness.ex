defmodule Stc.Task.LivenessCheck do
  @moduledoc """
  Configuration for a tasks liveness probe run by the executor.

  If the task module implements `running?/3`, the executor calls it on
  `interval_ms` and tracks failures within a `window_ms` rolling window.
  Once `max_failures` failures accumulate in that window the task is
  declared dead and failed with `{:liveness_check_failed, last_reason}`.
  """

  defstruct interval_ms: :timer.seconds(10), max_failures: 3, window_ms: :timer.seconds(30)

  @type t :: %__MODULE__{
          interval_ms: pos_integer(),
          max_failures: pos_integer(),
          window_ms: pos_integer()
        }
end
