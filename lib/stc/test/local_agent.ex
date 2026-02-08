defmodule STC.Agent.LocalTestAgent do
  @moduledoc """
  An executor that runs tasks on agents
  """
  defstruct [
    :id,
    :status
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: atom()
        }
end
