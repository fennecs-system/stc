defmodule Stc.Scheduler.Executor.State do
  @moduledoc """
  State of the executor
  """

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          task_id: String.t(),
          task_spec: Stc.Task.Spec.t(),
          agents: [Stc.Agent.t()],
          agent_ids: [String.t()],
          scheduler_id: String.t(),
          reply_buffer: pid(),
          attempt: pos_integer(),
          cluster_id: String.t() | nil,
          space_id: String.t() | nil,
          startup_timeout_ref: reference() | nil,
          task_timeout_ref: reference() | nil,
          duration_timeout_ref: reference() | nil,
          continue_check_refs: [reference()],
          # Handle returned by the task module for async tasks; used by liveness checks.
          async_handle: term(),
          # Monotonic millisecond timestamps of recent liveness-check failures.
          liveness_check_failures: [integer()]
        }

  defstruct [
    :workflow_id,
    :task_id,
    :task_spec,
    :agents,
    :agent_ids,
    :scheduler_id,
    :reply_buffer,
    :attempt,
    :cluster_id,
    :space_id,
    content_hash: nil,
    async_handle: nil,
    startup_timeout_ref: nil,
    task_timeout_ref: nil,
    duration_timeout_ref: nil,
    continue_check_refs: [],
    liveness_check_failures: []
  ]
end
