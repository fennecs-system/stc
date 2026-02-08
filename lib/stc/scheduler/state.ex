defmodule STC.Scheduler.State do
  @moduledoc """
  The state of the scheduler
  """
  defstruct [
    :id,
    # what level does this scheduler operate at? local? space? cluster?
    :level,
    :agent_pool,
    # agents that might be temporarily inactive - eg small timeout,
    :stale_agent_pool,
    :algorithm,
    # agent_id => [task_id]
    :agent_tasks,
    :task_locks,
    # task_id => {pid, os pid, systemd unit etc}
    :active_tasks,
    :event_loop_ref,
    # AgentReplyBuffer.t()
    :reply_buffer
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          level: atom(),
          agent_pool: list(),
          stale_agent_pool: list(),
          algorithm: module(),
          agent_tasks: map(),
          task_locks: map(),
          active_tasks: map(),
          event_loop_ref: reference() | nil,
          reply_buffer: pid()
        }
end
