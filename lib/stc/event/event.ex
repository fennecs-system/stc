defmodule Stc.Event do
  @moduledoc false

  defmodule Ready do
    @moduledoc false

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            module: module() | nil,
            payload: map() | nil,
            space_affinity: term(),
            cluster_affinity: term(),
            scheduler_affinity: [atom()] | nil,
            timestamp: DateTime.t() | nil,
            scheduled?: boolean() | nil,
            content_hash: String.t() | nil,
            policies: Stc.Task.Policy.t() | nil,
            schedule_attempts: non_neg_integer(),
            duration_ms: pos_integer() | nil
          }

    defstruct [
      :workflow_id,
      :task_id,
      :module,
      :payload,
      :space_affinity,
      :timestamp,
      :scheduled?,
      :duration_ms,
      cluster_affinity: nil,
      scheduler_affinity: nil,
      content_hash: nil,
      policies: nil,
      schedule_attempts: 0
    ]
  end

  defmodule Started do
    @moduledoc false

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            agent_ids: [String.t()] | nil,
            async_handle: term(),
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :agent_ids, :async_handle, :timestamp]
  end

  defmodule Completed do
    @moduledoc false

    alias Stc.Task.Result

    @type t :: %__MODULE__{
            workflow_id: String.t(),
            task_id: String.t(),
            agent_ids: [String.t()] | nil,
            result: Result.t(),
            attempt: pos_integer() | nil,
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :agent_ids, :result, :attempt, :timestamp]
  end

  defmodule Pending do
    @moduledoc """
    Emitted when a task cannot be scheduled immediately.

    Like Kubernetes `Pending` with `conditions`, this event carries all the information
    the scheduler needs to re-attempt scheduling without consulting other sources.
    Each re-attempt that still fails emits a new `Pending` with an incremented
    `schedule_attempts` counter.
    """

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            module: module() | nil,
            payload: map() | nil,
            policies: Stc.Task.Policy.t() | nil,
            space_affinity: term(),
            cluster_affinity: term(),
            scheduler_affinity: [atom()] | nil,
            content_hash: String.t() | nil,
            conditions: term(),
            last_schedule_attempt: DateTime.t() | nil,
            schedule_attempts: non_neg_integer() | nil,
            timestamp: DateTime.t() | nil,
            duration_ms: pos_integer() | nil
          }

    defstruct [
      :workflow_id,
      :task_id,
      :module,
      :payload,
      :policies,
      :space_affinity,
      :cluster_affinity,
      :scheduler_affinity,
      :content_hash,
      :conditions,
      :last_schedule_attempt,
      :schedule_attempts,
      :timestamp,
      :duration_ms
    ]

    @doc "Builds a Pending event from a Ready event that could not be scheduled."
    @spec from_ready(Stc.Event.Ready.t(), conditions :: term()) :: t()
    def from_ready(%Stc.Event.Ready{} = ready, conditions) do
      now = DateTime.utc_now()

      %__MODULE__{
        workflow_id: ready.workflow_id,
        task_id: ready.task_id,
        module: ready.module,
        payload: ready.payload,
        policies: ready.policies,
        space_affinity: ready.space_affinity,
        cluster_affinity: ready.cluster_affinity,
        scheduler_affinity: ready.scheduler_affinity,
        content_hash: ready.content_hash,
        conditions: conditions,
        schedule_attempts: ready.schedule_attempts + 1,
        last_schedule_attempt: now,
        duration_ms: ready.duration_ms,
        timestamp: now
      }
    end

    @doc "Reconstructs a Ready event from this Pending one, resetting the timestamp."
    @spec to_ready(t()) :: Stc.Event.Ready.t()
    def to_ready(%__MODULE__{} = p) do
      %Stc.Event.Ready{
        workflow_id: p.workflow_id,
        task_id: p.task_id,
        module: p.module,
        payload: p.payload,
        policies: p.policies,
        space_affinity: p.space_affinity,
        cluster_affinity: p.cluster_affinity,
        scheduler_affinity: p.scheduler_affinity,
        content_hash: p.content_hash,
        schedule_attempts: p.schedule_attempts,
        duration_ms: p.duration_ms,
        timestamp: DateTime.utc_now()
      }
    end
  end

  defmodule Stop do
    @moduledoc """
    Requests cancellation of a task or all tasks in a workflow.
    Broadcast via the shared event log; every scheduler and the walker act independently.
    """
    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            reason: term(),
            timestamp: DateTime.t() | nil
          }
    defstruct [:workflow_id, :task_id, :reason, :timestamp]
  end

  defmodule Rejected do
    @moduledoc "# planned - terminal event for permanently denied tasks"

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            reason: term(),
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :reason, :timestamp]
  end

  defmodule Preempted do
    @moduledoc """
    Emitted by the executor when the scheduler preempts a running task due to
    agent dropout.

    Distinct from `Failed`: the task itself did not error — the infrastructure
    running it became unhealthy or unavailable. The scheduler re-emits `Ready`
    for tasks it intends to reschedule; tasks for which no spare agents exist
    receive `Failed{reason: {:agent_unavailable, agent_id}}` instead.
    """

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            agent_ids: [String.t()] | nil,
            reason: term(),
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :agent_ids, :reason, :timestamp]
  end

  defmodule Failed do
    @moduledoc false

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            agent_ids: [String.t()] | nil,
            reason: term(),
            retriable: boolean() | nil,
            attempt: pos_integer() | nil,
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :agent_ids, :reason, :retriable, :attempt, :timestamp]
  end

  # planned
  # maybe agents can send back a progress chunk
  defmodule Progress do
    @moduledoc false

    @type t :: %__MODULE__{
            task_id: String.t() | nil,
            progress: term(),
            timestamp: DateTime.t() | nil
          }

    defstruct [:task_id, :progress, :timestamp]
  end
end
