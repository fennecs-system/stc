defmodule Stc.StaleLockTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Stc.Backend.Memory.EventLog
  alias Stc.Event.Store

  setup do
    start_supervised!(EventLog)
    :ok
  end

  property "release_locks_by_caller removes only locks owned by that caller" do
    check all(
            tasks <- uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 1),
            caller_a = "caller_a",
            caller_b = "caller_b",
            max_runs: 30
          ) do
      # Reset between iterations — check all runs multiple times against the
      # same supervised EventLog process so prior iteration locks would bleed in.
      Store.release_locks_by_caller(caller_a)
      Store.release_locks_by_caller(caller_b)

      {a_tasks, b_tasks} = Enum.split(tasks, div(length(tasks), 2))

      for t <- a_tasks, do: {:ok, _} = Store.try_lock(t, make_ref(), caller_a)
      for t <- b_tasks, do: {:ok, _} = Store.try_lock(t, make_ref(), caller_b)

      :ok = Store.release_locks_by_caller(caller_a)

      # All caller_a locks are gone — caller_b acquires them freely.
      for t <- a_tasks do
        assert {:ok, _} = Store.try_lock(t, make_ref(), caller_b)
      end

      # caller_b's original locks are still held.
      for t <- b_tasks do
        assert {:error, :locked} = Store.try_lock(t, make_ref(), caller_a)
      end
    end
  end

  test "release_locks_by_caller is a no-op when caller holds no locks" do
    {:ok, _} = Store.try_lock("task-1", :lock, "other_caller")
    :ok = Store.release_locks_by_caller("nobody")
    assert {:error, :locked} = Store.try_lock("task-1", :lock2, "anyone_else")
  end

  test "release_locks_by_caller is idempotent" do
    {:ok, _} = Store.try_lock("task-x", :lock, "scheduler-1")
    :ok = Store.release_locks_by_caller("scheduler-1")
    :ok = Store.release_locks_by_caller("scheduler-1")
    assert {:ok, _} = Store.try_lock("task-x", :lock2, "scheduler-2")
  end
end
