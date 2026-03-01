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
            policies: Stc.Task.Policy.t() | nil
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
      policies: nil
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

  # planned - like kubernetes for failure states like no nodes
  # or no budget or something that can be recovered
  defmodule Pending do
    @moduledoc false

    @type t :: %__MODULE__{
            workflow_id: String.t() | nil,
            task_id: String.t() | nil,
            module: module() | nil,
            payload: map() | nil,
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
      :conditions,
      :last_schedule_attempt,
      :schedule_attempts,
      :timestamp
    ]
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
