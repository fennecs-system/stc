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
            schedule_attempts: non_neg_integer()
          }

    defstruct [
      :workflow_id,
      :task_id,
      :module,
      :payload,
      :space_affinity,
      :timestamp,
      :scheduled?,
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
            timestamp: DateTime.t() | nil
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
      :timestamp
    ]
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

  # planned -
  # eg a cloud node died
  defmodule Preempted do
    @moduledoc false

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            preempted_by: term(),
            reason: term(),
            timestamp: DateTime.t() | nil
          }

    defstruct [:workflow_id, :task_id, :preempted_by, :reason, :timestamp]
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
