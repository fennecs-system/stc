defmodule STC.Agent do
  @moduledoc """
  A generic behaviour for STC agents
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
