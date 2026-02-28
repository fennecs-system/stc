defmodule Stc.TaskResultTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Stc.Task.Result

  property "to_result/1 preserves the result value for any term" do
    check all(value <- term()) do
      wrapped = Result.to_result(value)
      assert wrapped.result == value
    end
  end

  property "wrap/2 stores meta as-is" do
    check all(
            value <- term(),
            meta <- map_of(atom(:alphanumeric), term())
          ) do
      wrapped = Result.to_result(value, meta)
      assert wrapped.result == value
      assert wrapped._meta == meta
    end
  end

  property "_meta defaults to an empty map" do
    check all(value <- term()) do
      assert Result.to_result(value)._meta == %{}
    end
  end

  # A pure function that encodes the dispatch decision so it can be tested
  # without spinning up processes.
  defp dispatch_mode(module, stale_handle) do
    cond do
      stale_handle != nil and Stc.Task.resumable?(module) -> :resume
      stale_handle != nil -> :clean_and_start
      true -> :start
    end
  end

  property "dispatch is :start when there is no stale handle, regardless of module" do
    check all(_ignored <- integer()) do
      assert dispatch_mode(Stc.Task.TestAddTask, nil) == :start
    end
  end

  test "dispatch is :resume when module implements resume and handle exists" do
    defmodule ResumableTask do
      @behaviour Stc.Task
      alias Stc.Task.Result
      def start(_, _), do: {:ok, %Result{result: :started}}
      def resume(_, _handle, _), do: {:ok, %Result{result: :resumed}}
    end

    assert dispatch_mode(ResumableTask, "some-handle") == :resume
  end

  test "dispatch is :clean_and_start when module lacks resume but handle exists" do
    assert dispatch_mode(Stc.Task.TestAddTask, "some-handle") == :clean_and_start
  end

  test "dispatch is :start when handle is nil even if module has resume" do
    defmodule ResumableTask2 do
      @behaviour Stc.Task
      alias Stc.Task.Result
      def start(_, _), do: {:ok, %Result{result: :started}}
      def resume(_, _handle, _), do: {:ok, %Result{result: :resumed}}
    end

    assert dispatch_mode(ResumableTask2, nil) == :start
  end

  test "resumable? is false for a module without resume/3" do
    refute Stc.Task.resumable?(Stc.Task.TestAddTask)
  end

  test "resumable? is true for a module with resume/3" do
    defmodule ResumableTask3 do
      @behaviour Stc.Task
      alias Stc.Task.Result
      def start(_, _), do: {:ok, %Result{result: :ok}}
      def resume(_, _handle, _), do: {:ok, %Result{result: :resumed}}
    end

    assert Stc.Task.resumable?(ResumableTask3)
  end
end
