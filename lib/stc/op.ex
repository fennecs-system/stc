defmodule Stc.Op do
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

  defmodule Unfold do
    @moduledoc """
    A streaming/pagination op.

    `step_fn` maps the result of the previous step (or the initial seed) to either
    `{:cont, program}` — run `program` and continue — or `:halt` — stop and propagate
    the last result outward through the continuation.

    `current_step` holds the in-progress program for the current iteration. It must be
    stored explicitly (rather than re-derived from the seed) so that partial advancement
    by the walker is preserved across ticks.
    """
    @type step_fn :: (seed :: term() -> {:cont, term()} | :halt)

    @type t :: %__MODULE__{
            step_fn: step_fn(),
            current_step: term()
          }

    defstruct [:step_fn, :current_step]
  end
end
