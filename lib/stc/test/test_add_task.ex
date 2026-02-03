defmodule STC.Task.TestAddTask do
  @moduledoc false
  @behaviour STC.Task

  @impl true
  def execute(%{payload: %{a: a, b: b}}, _context \\ []) do
    {:ok, a + b}
  end
end
