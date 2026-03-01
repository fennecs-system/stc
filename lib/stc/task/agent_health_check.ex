defmodule Stc.Task.AgentHealthCheck do
  @moduledoc """
  Configuration for scheduler-level agent health monitoring.

  When the scheduler detects an agent's status change it applies a tolerance
  window before acting. Mirrors Kubernetes taint-based eviction:

  - `:unhealthy` agents (not-ready) are tolerated for `unhealthy_toleration_ms`
    before their tasks are evicted (default: 5 minutes).
  - `:unavailable` agents (unreachable / gone) are tolerated for
    `unavailable_toleration_ms` before eviction (default: 0 ms — immediate).

  Unlike `LivenessCheck` (which the task module drives against its own process),
  this check is driven entirely by the scheduler from agent pool state. It is
  a distinct failure class: the task itself may be healthy, but the infrastructure
  running it has dropped out.
  """

  defstruct unhealthy_toleration_ms: :timer.minutes(5),
            unavailable_toleration_ms: 0

  @type t :: %__MODULE__{
          unhealthy_toleration_ms: non_neg_integer(),
          unavailable_toleration_ms: non_neg_integer()
        }
end
