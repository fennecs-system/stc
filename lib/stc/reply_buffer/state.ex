defmodule Stc.ReplyBuffer.State do
  @moduledoc false
  defstruct scheduler_id: nil, buffer: %{}, executors: %{}, monitors: %{}

  @type entry :: %{
          task_id: String.t(),
          agent_id: String.t(),
          message: term(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          scheduler_id: String.t(),
          buffer: %{String.t() => [entry()]},
          executors: %{String.t() => pid()},
          monitors: %{reference() => String.t()}
        }
end
