defmodule STC.SchedulerTest do
  use ExUnit.Case

  alias STC.Scheduler
  alias STC.Scheduler.Algorithm.LocalTestAlgorithm

  alias STC.Event.Store

  alias STC.Interpreter
  alias STC.Interpreter.Distributed

  alias STC.Program
  alias STC.Program.Store, as: ProgramStore

  import STC.Free

  alias STC.Task.TestAddTask

  setup do
    {:ok, sched_reg_pid} =
      Horde.Registry.start_link(
        name: STC.SchedulerRegistry,
        keys: :unique,
        members: :auto
      )

    {:ok, exe_reg_pid} =
      Horde.Registry.start_link(
        name: STC.ExecutorRegistry,
        keys: :unique,
        members: :auto
      )

    {:ok, event_store_pid} = Store.start_link([])

    # spawn a horde registry for schedulers
    # currently needs to spawn after event store
    {:ok, interp_pid} = Distributed.start_link([])
    {:ok, prog_store_pid} = ProgramStore.start_link([])

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
