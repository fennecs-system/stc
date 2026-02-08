defmodule STC.Op do
  @moduledoc """
  woof woof bark bark oppies for the free monad
  """

  defmodule Run do
    @moduledoc false
    defstruct [:task_id, :module, :payload, :cluster_affinity, :space_affinity, :agent_affinity]
  end

  # for reversing a Run op
  defmodule Clean do
    @moduledoc false
    defstruct [:task_id, :module, :payload, :cluster_affinity, :space_affinity, :agent_affinity]
  end

  # for scheduling purposes
  defmodule Pause do
    @moduledoc false
    defstruct [:task_id]
  end

  defmodule Resume do
    @moduledoc false
    defstruct [:task_id]
  end

  defmodule Terminate do
    @moduledoc false
    defstruct [:task_id]
  end

  defmodule Sequence do
    @moduledoc false
    defstruct [:programs]
  end

  defmodule Parallel do
    @moduledoc false
    defstruct [:programs]
  end

  defmodule Wait do
    @moduledoc false
    defstruct [:task_id, :continuation]
  end

  defmodule OnFailure do
    @moduledoc false
    defstruct [:task_id, :handler, :continuation]
  end

  defmodule EmitEvent do
    @moduledoc false
    defstruct [:event, :continuation]
  end
end
