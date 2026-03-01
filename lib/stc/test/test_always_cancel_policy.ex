defmodule Stc.Task.TestAlwaysCancelPolicy do
  @moduledoc false
  @behaviour Stc.Task.Policy.Continue

  defstruct []

  @impl true
  def continue(%__MODULE__{}, _context) do
    {:cancel, :test_cancel}
  end
end
