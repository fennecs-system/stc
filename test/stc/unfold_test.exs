defmodule Stc.UnfoldTest do
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

  describe "local" do
    setup do
      start_supervised!(Stc.Backend.Memory.EventLog)
      start_supervised!(Stc.Backend.Memory.KV)
      :ok
    end

    test "counts up from 0, halting when result reaches 3" do
      # seed=0 → task(0+1)=1 → task(1+1)=2 → task(2+1)=3 → halt
      # final result: 3
      program =
        unfold(0, fn
          n when n < 3 -> {:cont, Program.run(TestAddTask, %{a: n, b: 1})}
          _ -> :halt
        end)

      assert {:ok, 3} = Interpreter.local(program, %{})
    end

    test "halts immediately when seed already satisfies halt condition" do
      program =
        unfold(5, fn
          n when n < 3 -> {:cont, Program.run(TestAddTask, %{a: n, b: 1})}
          _ -> :halt
        end)

      # step_fn.(5) == :halt so unfold/2 returns {:pure, 5} directly — no tasks run
      assert {:ok, 5} = Interpreter.local(program, %{})
    end

    test "composes with bind — final result feeds the outer continuation" do
      # unfold counts to 3, bind doubles it
      program =
        unfold(0, fn
          n when n < 3 -> {:cont, Program.run(TestAddTask, %{a: n, b: 1})}
          _ -> :halt
        end)
        |> bind(fn n -> Program.run(TestAddTask, %{a: n, b: n}) end)

      # unfold → 3, bind → 3 + 3 = 6
      assert {:ok, 6} = Interpreter.local(program, %{})
    end
  end

  describe "distributed" do
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
          algorithm: LocalTestAlgorithm,
          id: "unfold_test_scheduler",
          level: :local
        )

      :ok
    end

    defp assert_eventually(fun, timeout_ms \\ 10_000, interval_ms \\ 100) do
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

    test "runs steps sequentially and reaches pure terminal state" do
      program =
        unfold(0, fn
          n when n < 3 -> {:cont, Program.run(TestAddTask, %{a: n, b: 1})}
          _ -> :halt
        end)

      Interpreter.distributed(program, %{workflow_id: "unfold_dist_1"})

      assert_eventually(fn ->
        match?({:ok, {:pure, 3}}, ProgramStore.get("unfold_dist_1"))
      end)

      assert {:ok, {:pure, 3}} = ProgramStore.get("unfold_dist_1")

      # Exactly 3 tasks completed — one per step, in sequence.
      {:ok, completed, _} = Store.fetch(Store.origin(), types: [Stc.Event.Completed])
      assert length(completed) == 3
      assert Enum.map(completed, & &1.result.value) |> Enum.sort() == [1, 2, 3]
    end

    test "only one step is in-flight at a time" do
      # Each Ready event should appear only after the previous Completed event.
      # We verify this by checking that Ready events are interleaved with Completed
      # events in the log rather than all appearing upfront.
      program =
        unfold(0, fn
          n when n < 3 -> {:cont, Program.run(TestAddTask, %{a: n, b: 1})}
          _ -> :halt
        end)

      Interpreter.distributed(program, %{workflow_id: "unfold_dist_2"})

      assert_eventually(fn ->
        match?({:ok, {:pure, 3}}, ProgramStore.get("unfold_dist_2"))
      end)

      {:ok, all_events, _} =
        Store.fetch(Store.origin(),
          types: [Stc.Event.Ready, Stc.Event.Completed]
        )

      # Events should interleave: Ready, Completed, Ready, Completed, Ready, Completed
      types = Enum.map(all_events, & &1.__struct__)

      assert types == [
               Stc.Event.Ready,
               Stc.Event.Completed,
               Stc.Event.Ready,
               Stc.Event.Completed,
               Stc.Event.Ready,
               Stc.Event.Completed
             ]
    end
  end
end
