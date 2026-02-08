defmodule STC.Event do
  @moduledoc false

  defmodule Ready do
    @moduledoc false
    defstruct [
      :workflow_id,
      :task_id,
      :module,
      :payload,
      :space_affinity,
      :timestamp,
      :scheduled?
    ]
  end

  defmodule Started do
    @moduledoc false
    defstruct [:workflow_id, :task_id, :agent_ids, :async_handle, :timestamp]
  end

  defmodule Completed do
    @moduledoc false
    defstruct [:workflow_id, :task_id, :agent_ids, :result, :attempt, :timestamp]
  end

  defmodule Failed do
    @moduledoc false
    defstruct [:workflow_id, :task_id, :agent_ids, :reason, :retriable, :attempt, :timestamp]
  end

  defmodule Progress do
    @moduledoc false
    defstruct [:task_id, :progress, :timestamp]
  end
end
