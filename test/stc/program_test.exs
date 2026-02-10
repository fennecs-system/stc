defmodule Stc.ProgramTest do
  use ExUnit.Case

  alias Stc.Interpreter
  alias Stc.Event.Store
  alias Stc.Program

  alias Stc.Task.TestAddTask

  import Stc.Free

  test "basic addition test" do
    # (1 + 1) + (1 + 1) + 1
    # three tasks, two parallel, one sequence

    {:ok, event_store} = Store.start_link([])

    program =
      Program.parallel([
        Program.run(TestAddTask, %{a: 1, b: 1}),
        Program.run(TestAddTask, %{a: 1, b: 1})
      ])
      |> bind(fn
        [2, 2] ->
          Program.run(
            TestAddTask,
            %{a: 2, b: 2 + 10}
          )

        [r1, r2] ->
          Program.run(
            TestAddTask,
            %{a: r1, b: r2 + 1}
          )
      end)

    # cant print the result of the bind
    Interpreter.trace(program)
    assert {:ok, 14} == Interpreter.local(program, %{})

    # check that events were logged
    # |> IO.inspect(label: "Event Store State")
    _state = :sys.get_state(event_store) |> dbg()
  end
end
