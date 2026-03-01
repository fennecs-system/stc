defmodule Stc.Interpreter.Distributed.State do
  @moduledoc false

  @type t :: %__MODULE__{
          cursor: Stc.Backend.EventLog.cursor()
        }

  defstruct [:cursor]
end
