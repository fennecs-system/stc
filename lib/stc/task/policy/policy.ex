defmodule Stc.Task.Policy do
  @moduledoc """
  Container for all policies that govern how a task is admitted and executed.

  - `admit`    -- list of structs implementing `Stc.Task.Policy.Admit`.
                 Evaluated by the scheduler before dispatching; rejection defers the task.
  - `retry`    -- controls retry behaviour on failure (`Stc.Task.Policy.Retry`).
  - `continue` -- list of structs implementing `Stc.Task.Policy.Continue`,
                 checked by the scheduler each tick while the task is running.
  """

  alias Stc.Task.Policy.Admit
  alias Stc.Task.Policy.Continue
  alias Stc.Task.Policy.Retry

  @type t :: %__MODULE__{
          admit: [Admit.t()],
          retry: Retry.t(),
          continue: [Continue.t()]
        }

  defstruct admit: [],
            retry: %Retry{},
            continue: []
end
