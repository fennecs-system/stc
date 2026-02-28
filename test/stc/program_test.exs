defmodule Stc.ProgramTest do
  use ExUnit.Case

  import Stc.Free

  alias Stc.Interpreter
  alias Stc.Program
  alias Stc.Task.TestAddTask

  setup do
    start_supervised!(Stc.Backend.Memory.EventLog)
    start_supervised!(Stc.Backend.Memory.KV)
    :ok
  end

  test "basic addition test" do
    # (1 + 1) || (1 + 1) >>= fn [2, 2] -> 2 + (2 + 10) = 14
    program =
      Program.parallel([
        Program.run(TestAddTask, %{a: 1, b: 1}),
        Program.run(TestAddTask, %{a: 1, b: 1})
      ])
      |> bind(fn
        [2, 2] ->
          Program.run(TestAddTask, %{a: 2, b: 2 + 10})

        [r1, r2] ->
          Program.run(TestAddTask, %{a: r1, b: r2 + 1})
      end)

    Interpreter.trace(program)
    assert {:ok, 14} == Interpreter.local(program, %{})
  end
end
