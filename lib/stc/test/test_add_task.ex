defmodule Stc.Task.TestAddTask do
  @moduledoc false
  @behaviour Stc.Task

  @impl true
  def start(%{payload: %{a: a, b: b}}, _context \\ []) do
    {:ok, a + b}
  end
end
