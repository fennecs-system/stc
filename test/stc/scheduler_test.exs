defmodule Stc.SchedulerTest do
  use ExUnit.Case

  import Stc.Free

  alias Stc.Event.Store
  alias Stc.Interpreter
  alias Stc.Interpreter.Distributed
  alias Stc.Program
  alias Stc.Program.Store, as: ProgramStore
  alias Stc.Scheduler
  alias Stc.Scheduler.Algorithm.LocalTestAlgorithm
  alias Stc.Task.TestAddTask

  setup do
    start_supervised!(
      {Horde.Registry, name: Stc.SchedulerRegistry, keys: :unique, members: :auto},
      id: :sched_registry
    )

    start_supervised!(
      {Horde.Registry, name: Stc.ExecutorRegistry, keys: :unique, members: :auto},
      id: :exe_registry
    )

    start_supervised!(Stc.Backend.Memory.EventLog)
    start_supervised!(Stc.Backend.Memory.KV)

    # Distributed walker must start after backends are up.
    start_supervised!(Distributed)

    :ok
  end

  defp assert_eventually(fun, timeout_ms \\ 10_000, interval_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("assert_eventually timed out")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end

  defp all_completed do
    {:ok, events, _cursor} = Store.fetch(Store.origin(), types: [Stc.Event.Completed])
    events
  end

  test "can start a scheduler" do
    {:ok, scheduler} =
      Scheduler.start_link(
        algorithm: LocalTestAlgorithm,
        id: "test_scheduler_1",
        level: :local
      )

    assert Process.alive?(scheduler)

    # parallel(add1 || add2) >>= fn [r1, r2] -> add3(r1, r2 + 1)
    # add1 = 1+1 = 2, add2 = 1+1 = 2, add3 = 2 + (2+1) = 5
    program =
      Program.parallel([
        Program.run(TestAddTask, %{a: 1, b: 1}, :add1),
        Program.run(TestAddTask, %{a: 1, b: 1}, :add2)
      ])
      |> bind(fn [r1, r2] ->
        Program.run(TestAddTask, %{a: r1, b: r2 + 1}, :add3)
      end)

    Interpreter.distributed(program, %{workflow_id: "test_workflow_1"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("test_workflow_1"))
    end)

    assert {:ok, {:pure, 5}} = ProgramStore.get("test_workflow_1")

    results_by_task = Map.new(all_completed(), fn e -> {e.task_id, e.result.value} end)

    assert results_by_task[:add1] == 2
    assert results_by_task[:add2] == 2
    assert results_by_task[:add3] == 5
  end

  test "keeps running an infinite job" do
    {:ok, scheduler} =
      Scheduler.start_link(
        algorithm: LocalTestAlgorithm,
        id: "test_scheduler_2",
        level: :local
      )

    assert Process.alive?(scheduler)

    program =
      cycle(1, fn num ->
        Program.run(TestAddTask, %{a: num, b: 1})
      end)

    Interpreter.distributed(program, %{workflow_id: "infinite_workflow_2"})

    # Wait for at least 3 iterations to complete.
    assert_eventually(fn -> length(all_completed()) >= 3 end)

    results = all_completed() |> Enum.map(& &1.result.value) |> Enum.sort()

    assert 2 in results
    assert 3 in results
    assert 4 in results

    # A cycle should never reach a pure terminal state.
    {:ok, current_program} = ProgramStore.get("infinite_workflow_2")
    refute match?({:pure, _}, current_program)
  end
end
