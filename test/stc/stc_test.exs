defmodule STCTest do
  use DataCase, async: false

  alias STC.Interpreter
  alias STC.Event.Store
  alias STC.Program

  alias STC.Tasks.TestAddTask

  import STC.Free

  test "basic addition test" do
    # (1 + 1) + (1 + 1) + 1
    # three tasks, two parallel, one sequence

    {:ok, event_store} = Store.start_link([])

    program =
      Program.parallel([
        Program.run(TestAddTask, %{a: 1, b: 1}, :add1),
        Program.run(TestAddTask, %{a: 1, b: 1}, :add2)
      ])
      |> bind(fn results ->
        [r1, r2] = results

        Program.run(
          TestAddTask,
          %{a: r1, b: r2 + 1},
          :add_3
        )
      end)

    # cant print the result of the bind
    Interpreter.trace(program)
    assert {:ok, 5} == Interpreter.local(program, %{})

    # check that events were logged
    # |> IO.inspect(label: "Event Store State")
    _state = :sys.get_state(event_store)
  end
end
