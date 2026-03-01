defmodule Stc.Op do
  @moduledoc """
  woof woof bark bark oppies for the free monad
  """

  defmodule Run do
    @moduledoc false
    defstruct [
      :task_id,
      :module,
      :payload,
      :cluster_affinity,
      :space_affinity,
      :scheduler_affinity,
      :agent_affinity,
      :duration_ms,
      store: false,
      policies: %Stc.Task.Policy{}
    ]
  end

  # planned -
  # for reversing a Run op
  # however tasks now have a Clean step so this might just be equivalent to a Run
  # perhaps we could emit a Clean event instead
  defmodule Clean do
    @moduledoc false
    defstruct [:task_id, :module, :payload, :cluster_affinity, :space_affinity, :agent_affinity]
  end

  # probably need some semantics for moving a job between spaces
  # eg its currently tunning on one space affinity - needs to be
  # moved to a different space
  # somehow does something to an entire workflow tho
  # changes affinitiess
  # need to gracefully move
  defmodule Move do
    @moduledoc false
    defstruct [:task_id]
  end

  # planned -
  # for scheduling purposes
  defmodule Pause do
    @moduledoc false
    defstruct [:task_id]
  end

  # planned
  defmodule Resume do
    @moduledoc false
    defstruct [:task_id]
  end

  # planned
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

  # planned
  defmodule Wait do
    @moduledoc false
    defstruct [:task_id, :continuation]
  end

  # planned
  defmodule OnFailure do
    @moduledoc false
    defstruct [:task_id, :handler, :continuation]
  end

  # planned
  # hook to be able to emit generic events - for other stuff to happen
  # kind of dynamic
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
