defmodule Stc.TaskStoreTest do
  use ExUnit.Case

  import Stc.Free

  alias Stc.Event.Store
  alias Stc.Interpreter
  alias Stc.Interpreter.Distributed
  alias Stc.Program
  alias Stc.Program.Store, as: ProgramStore
  alias Stc.Scheduler
  alias Stc.Scheduler.Algorithm.LocalTestAlgorithm
  alias Stc.Task.Store, as: TaskStore
  alias Stc.Task.TestAddTask

  @scheduler_opts [scheduler_tick_rate_ms: 100]

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

    {:ok, _} =
      Scheduler.start_link(
        [algorithm: LocalTestAlgorithm, id: "store_sched", level: :local] ++ @scheduler_opts
      )

    :ok
  end

  defp assert_eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 50) do
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

  defp completed_events do
    {:ok, events, _} = Store.fetch(Store.origin(), types: [Stc.Event.Completed])
    events
  end

  defp ready_events do
    {:ok, events, _} = Store.fetch(Store.origin(), types: [Stc.Event.Ready])
    events
  end

  test "store: true caches result and skips execution on second run" do
    hash = TaskStore.content_hash(TestAddTask, %{a: 7, b: 3})

    # Pre-condition: nothing in cache
    assert {:error, :not_found} = TaskStore.get(hash)

    # First run — cache miss, task executes normally
    program1 = Program.run(TestAddTask, %{a: 7, b: 3}, store: true)
    Interpreter.distributed(program1, %{workflow_id: "store_wf_1"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("store_wf_1"))
    end)

    assert {:ok, {:pure, 10}} = ProgramStore.get("store_wf_1")

    # Result is now in the store
    assert {:ok, %Stc.Task.Result{value: 10}} = TaskStore.get(hash)

    ready_count_after_first = length(ready_events())
    completed_count_after_first = length(completed_events())

    # Second run — same inputs, different workflow; hits the cache directly
    program2 = Program.run(TestAddTask, %{a: 7, b: 3}, store: true)
    Interpreter.distributed(program2, %{workflow_id: "store_wf_2"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("store_wf_2"))
    end)

    assert {:ok, {:pure, 10}} = ProgramStore.get("store_wf_2")

    # No new Ready event was emitted for the second run (went straight to Completed)
    assert length(ready_events()) == ready_count_after_first
    # One additional Completed (the synthetic cache-hit one)
    assert length(completed_events()) == completed_count_after_first + 1
  end

  test "store: true deduplicates in a sequence when second task is cached" do
    # Run task B standalone first to warm the cache
    cache_program = Program.run(TestAddTask, %{a: 2, b: 10}, store: true)
    Interpreter.distributed(cache_program, %{workflow_id: "store_seq_warmup"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("store_seq_warmup"))
    end)

    # Now run A -> B in sequence where B is cached
    # A: 1+1=2, B: 2+10=12 (cached)
    program =
      Program.run(TestAddTask, %{a: 1, b: 1})
      |> bind(fn r ->
        Program.run(TestAddTask, %{a: r, b: 10}, store: true)
      end)

    ready_count_before = length(ready_events())

    Interpreter.distributed(program, %{workflow_id: "store_seq_wf"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("store_seq_wf"))
    end)

    assert {:ok, {:pure, 12}} = ProgramStore.get("store_seq_wf")

    # Only 1 Ready event for task A (task B was served from cache by the walker)
    assert length(ready_events()) == ready_count_before + 1
  end

  test "store: false tasks are not cached" do
    program = Program.run(TestAddTask, %{a: 4, b: 4}, store: false)
    Interpreter.distributed(program, %{workflow_id: "no_store_wf"})

    assert_eventually(fn ->
      match?({:ok, {:pure, _}}, ProgramStore.get("no_store_wf"))
    end)

    hash = TaskStore.content_hash(TestAddTask, %{a: 4, b: 4})
    assert {:error, :not_found} = TaskStore.get(hash)
  end
end
