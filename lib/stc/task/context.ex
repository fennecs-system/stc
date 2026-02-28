defmodule Stc.Task.Context do
  @moduledoc """
  Execution context passed to a task's `start/2` and `clean/2` callbacks.

  Carries everything a task needs to know about its environment at dispatch time:
  which agents it is running on, where it sits in the workflow, and how to send
  replies back to the scheduler via the `reply_buffer`.

  ## Reply buffer

  For async tasks, agents signal progress and completion by calling
  `Stc.ReplyBuffer.add_message/4` with the `scheduler_id` (derivable from
  `reply_buffer`) and `task_id`. Supported message shapes:

    - `:started_tick`       — agent has begun processing; cancels startup timeout.
    - `{:result, result}`   — task completed successfully.
    - `{:failed, reason}`   — task failed; executor applies retry policy.
  """

  alias Stc.Task.Spec

  @type t :: %__MODULE__{
          agents: [Stc.Agent.t()],
          workflow_id: String.t(),
          task_id: String.t(),
          task_spec: Spec.t(),
          attempt: pos_integer(),
          cluster_id: String.t() | nil,
          space_id: String.t() | nil,
          reply_buffer: pid() | nil
        }

  defstruct [
    :agents,
    :workflow_id,
    :task_id,
    :task_spec,
    :attempt,
    :cluster_id,
    :space_id,
    :reply_buffer
  ]
end
