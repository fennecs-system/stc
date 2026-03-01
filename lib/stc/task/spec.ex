defmodule Stc.Task.Spec do
  @moduledoc """
  Generic specification for a task
  """

  alias Stc.Task.AgentHealthCheck
  alias Stc.Task.LivenessCheck
  alias Stc.Task.Policy

  defstruct [
    :module,
    :payload,
    :policies,
    :timeout_ms,
    :startup_timeout_ms,
    duration_ms: nil,
    liveness_check: nil,
    agent_health_check: nil
  ]

  @type t :: %__MODULE__{
          module: module(),
          payload: map(),
          policies: Policy.t(),
          startup_timeout_ms: pos_integer() | nil,
          timeout_ms: pos_integer() | nil,
          duration_ms: pos_integer() | nil,
          liveness_check: LivenessCheck.t() | nil,
          agent_health_check: AgentHealthCheck.t() | nil
        }

  @spec new(module(), map(), keyword()) :: t()
  def new(module, payload, opts \\ []) do
    policies = Keyword.get(opts, :policies, %Policy{})
    timeout_ms = Keyword.get(opts, :timeout_ms, :timer.hours(1))
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, :timer.hours(1))
    duration_ms = Keyword.get(opts, :duration_ms, nil)
    liveness_check = Keyword.get(opts, :liveness_check, nil)
    agent_health_check = Keyword.get(opts, :agent_health_check, nil)

    %__MODULE__{
      module: module,
      payload: payload,
      policies: policies,
      timeout_ms: timeout_ms,
      startup_timeout_ms: startup_timeout_ms,
      duration_ms: duration_ms,
      liveness_check: liveness_check,
      agent_health_check: agent_health_check
    }
  end
end
