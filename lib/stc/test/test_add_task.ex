defmodule Stc.Task.TestAddTask do
  @moduledoc false
  @behaviour Stc.Task

  alias Stc.Task.Result

  @impl true
  def start(%{payload: %{a: a, b: b}}, _context \\ []) do
    {:ok, %Result{result: a + b}}
  end
end
