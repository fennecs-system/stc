defmodule STC.LocalTestAgent do
  @moduledoc """
  An executor that runs tasks on agents
  """
  defstruct [
    :id
  ]

  @type t :: %__MODULE__{
          id: String.t()
        }
end
