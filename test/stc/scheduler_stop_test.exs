defmodule Stc.SchedulerStopTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Stc.Event.Store
  alias Stc.Interpreter
  alias Stc.Interpreter.Distributed
  alias Stc.Program
  alias Stc.Program.Store, as: ProgramStore
  alias Stc.Scheduler
  alias Stc.Scheduler.Algorithm.LocalTestAlgorithm
  alias Stc.Task.TestSleepTask

  @scheduler_opts [scheduler_tick_rate_ms: 100]

  # An admit policy that keeps tasks in Pending state indefinitely.
  defmodule AlwaysPendingPolicy do
    @behaviour Stc.Task.Policy.Admit
    defstruct []

    @impl true
    def admit(%__MODULE__{}, _context), do: {:pending, :always_pending}
  end

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
    start_supervised!(Distributed)

    :ok
  end

  defp assert_eventually(fun, timeout_ms \\ 2_000, interval_ms \\ 50) do
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

  defp failed_events_for(task_id) do
    {:ok, events, _} = Store.fetch(Store.origin(), types: [Stc.Event.Failed], task_id: task_id)
    events
  end

  defp started_events_for(task_id) do
    {:ok, events, _} = Store.fetch(Store.origin(), types: [Stc.Event.Started], task_id: task_id)
    events
  end

  defp executor_alive?(task_id) do
    case Horde.Registry.lookup(Stc.ExecutorRegistry, "executor_#{task_id}") do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  defp unique_id(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  # ---------------------------------------------------------------------------
  # Normal tests
  # ---------------------------------------------------------------------------

  test "stop_task cancels in-flight async task" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id = unique_id("task")
    program = Program.run(TestSleepTask, %{}, task_id)
    Interpreter.distributed(program, %{workflow_id: unique_id("wf")})

    assert_eventually(fn -> executor_alive?(task_id) end)

    Scheduler.stop_task(task_id)

    assert_eventually(fn ->
      Enum.any?(failed_events_for(task_id), &match?(%{reason: :cancelled}, &1))
    end)

    refute executor_alive?(task_id)
  end

  test "stop_workflow cancels all parallel tasks" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id1 = unique_id("t1")
    task_id2 = unique_id("t2")
    wf_id = unique_id("wf")

    program =
      Program.parallel([
        Program.run(TestSleepTask, %{}, task_id1),
        Program.run(TestSleepTask, %{}, task_id2)
      ])

    Interpreter.distributed(program, %{workflow_id: wf_id})

    assert_eventually(fn -> executor_alive?(task_id1) and executor_alive?(task_id2) end)

    Scheduler.stop_workflow(wf_id)

    assert_eventually(fn ->
      Enum.any?(failed_events_for(task_id1), &match?(%{reason: :cancelled}, &1)) and
        Enum.any?(failed_events_for(task_id2), &match?(%{reason: :cancelled}, &1))
    end)
  end

  test "stop_workflow cleans ProgramStore" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id = unique_id("task")
    wf_id = unique_id("wf")
    program = Program.run(TestSleepTask, %{}, task_id)
    Interpreter.distributed(program, %{workflow_id: wf_id})

    assert_eventually(fn -> executor_alive?(task_id) end)

    Scheduler.stop_workflow(wf_id)

    assert_eventually(
      fn -> match?({:error, :not_found}, ProgramStore.get(wf_id)) end,
      2_000
    )
  end

  test "stop_task prevents pending task from running" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id = unique_id("task")

    program =
      Program.run(TestSleepTask, %{}, task_id, admit_policies: [%AlwaysPendingPolicy{}])

    Interpreter.distributed(program, %{workflow_id: unique_id("wf")})

    # Wait for at least one Pending event for this task.
    assert_eventually(fn ->
      {:ok, events, _} =
        Store.fetch(Store.origin(), types: [Stc.Event.Pending], task_id: task_id)

      events != []
    end)

    Scheduler.stop_task(task_id)

    # Give the scheduler a few more ticks to process.
    Process.sleep(400)

    refute executor_alive?(task_id)
    assert started_events_for(task_id) == []
  end

  test "stop is a no-op for unknown task" do
    sched_id = unique_id("s")

    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: sched_id, level: :local] ++ @scheduler_opts
      )

    unknown_id = unique_id("nonexistent")
    {:ok, _cursor} = Scheduler.stop_task(unknown_id)

    # Confirm the Stop event was appended.
    assert_eventually(fn ->
      {:ok, events, _} = Store.fetch(Store.origin(), types: [Stc.Event.Stop])
      Enum.any?(events, &(&1.task_id == unknown_id))
    end)

    assert Scheduler.get_state(sched_id) != nil
  end

  test "duration_ms stops task after elapsed time" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id = unique_id("task")
    program = Program.run(TestSleepTask, %{}, task_id, duration_ms: 50)
    Interpreter.distributed(program, %{workflow_id: unique_id("wf")})

    assert_eventually(fn ->
      Enum.any?(failed_events_for(task_id), &match?(%{reason: :duration_elapsed}, &1))
    end)

    refute executor_alive?(task_id)
  end

  test "duration_ms fires before timeout when duration is shorter" do
    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
      )

    task_id = unique_id("task")
    # duration_ms: 50, timeout_ms: 10_000 — duration fires first
    program = Program.run(TestSleepTask, %{}, task_id, duration_ms: 50)
    Interpreter.distributed(program, %{workflow_id: unique_id("wf")})

    assert_eventually(fn ->
      events = failed_events_for(task_id)

      Enum.any?(events, &match?(%{reason: :duration_elapsed}, &1)) and
        not Enum.any?(events, &match?(%{reason: :task_timeout}, &1))
    end)
  end

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  property "stop always produces exactly one terminal event" do
    check all(
            stop_delay_ms <- integer(0..100),
            max_runs: 10
          ) do
      {:ok, sched_pid} =
        Scheduler.start_link(
          [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
        )

      task_id = unique_id("task")
      program = Program.run(TestSleepTask, %{}, task_id)
      Interpreter.distributed(program, %{workflow_id: unique_id("wf")})

      Process.sleep(stop_delay_ms)
      Scheduler.stop_task(task_id)

      assert_eventually(
        fn ->
          {:ok, completed, _} =
            Store.fetch(Store.origin(), types: [Stc.Event.Completed], task_id: task_id)

          {:ok, failed, _} =
            Store.fetch(Store.origin(), types: [Stc.Event.Failed], task_id: task_id)

          length(completed) + length(failed) == 1
        end,
        1_000
      )

      {:ok, completed, _} =
        Store.fetch(Store.origin(), types: [Stc.Event.Completed], task_id: task_id)

      {:ok, failed, _} =
        Store.fetch(Store.origin(), types: [Stc.Event.Failed], task_id: task_id)

      assert length(completed) <= 1
      assert length(failed) <= 1

      GenServer.stop(sched_pid, :normal, 500)
    end
  end

  property "stop_workflow terminates all tasks in a parallel workflow" do
    check all(n <- integer(1..4), max_runs: 10) do
      {:ok, sched_pid} =
        Scheduler.start_link(
          [algorithm: LocalTestAlgorithm, id: unique_id("s"), level: :local] ++ @scheduler_opts
        )

      task_ids = Enum.map(1..n, fn _ -> unique_id("task") end)
      wf_id = unique_id("wf")

      program = Program.parallel(Enum.map(task_ids, &Program.run(TestSleepTask, %{}, &1)))
      Interpreter.distributed(program, %{workflow_id: wf_id})

      assert_eventually(fn -> Enum.all?(task_ids, &executor_alive?/1) end, 2_000)

      Scheduler.stop_workflow(wf_id)

      assert_eventually(
        fn ->
          Enum.all?(task_ids, fn tid ->
            Enum.any?(failed_events_for(tid), &match?(%{reason: :cancelled}, &1))
          end)
        end,
        2_000
      )

      GenServer.stop(sched_pid, :normal, 500)
    end
  end
end
