defmodule Stc.SchedulerTest do
  use ExUnit.Case

  alias Stc.Scheduler
  alias Stc.Scheduler.Algorithm.LocalTestAlgorithm

  alias Stc.Event.Store

  alias Stc.Interpreter
  alias Stc.Interpreter.Distributed

  alias Stc.Program
  alias Stc.Program.Store, as: ProgramStore

  import Stc.Free

  alias Stc.Task.TestAddTask

  setup do
    sched_reg_pid =
      start_supervised!(
        {Horde.Registry, name: Stc.SchedulerRegistry, keys: :unique, members: :auto},
        id: :sched_registry
      )

    exe_reg_pid =
      start_supervised!(
        {Horde.Registry, name: Stc.ExecutorRegistry, keys: :unique, members: :auto},
        id: :exe_registry
      )

    start_supervised!(Store)

    # currently needs to spawn after event store
    start_supervised!(Distributed)
    start_supervised!(ProgramStore)

    %{executor_registry: exe_reg_pid, scheduler_registry: sched_reg_pid}
  end

  test "can start a scheduler", %{scheduler_registry: _pid} do
    {:ok, _scheduler} =
      Scheduler.start_link(
        algorithm: LocalTestAlgorithm,
        id: "test_scheduler_1",
        level: :local
      )

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
          :add3
        )
      end)

    Interpreter.distributed(program, %{workflow_id: "test_workflow_1"})

    # peak the scheduler state
    state =
      :sys.get_state(Scheduler.via("test_scheduler_1")) |> IO.inspect(label: "Scheduler State")

    Process.sleep(10_000)
    # terminate all pids
    ProgramStore.show() |> dbg()
  end

  test "keeps running an infinite job", %{scheduler_registry: _pid} do
    {:ok, _scheduler} =
      Scheduler.start_link(
        algorithm: LocalTestAlgorithm,
        id: "test_scheduler_2",
        level: :local
      )
      |> dbg()

    program =
      cycle(1, fn num ->
        Program.run(TestAddTask, %{a: num, b: 1})
      end)

    Interpreter.distributed(program, %{workflow_id: "infinite_workflow_2"})
    Process.sleep(10_000)
  end
end
