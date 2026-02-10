defmodule Stc.Agent do
  @moduledoc """
  A generic behaviour for Stc agents
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
