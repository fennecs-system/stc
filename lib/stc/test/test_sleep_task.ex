defmodule Stc.Task.TestSleepTask do
  @moduledoc false
  @behaviour Stc.Task

  @impl true
  def start(_spec, context) do
    pid = self()

    Task.start(fn ->
      Process.sleep(:infinity)
      send(pid, {:reply, context.task_id, :test, {:result, :ok}})
    end)

    {:started, :sleeping}
  end

  @impl true
  def clean(_spec, _context), do: :ok
end
