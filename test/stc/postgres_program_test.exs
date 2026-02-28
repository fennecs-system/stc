defmodule Stc.PostgresProgramTest do
  use ExUnit.Case, async: false

  alias Stc.Interpreter
  alias Stc.Program
  alias Stc.Task.TestAddTask

  import Stc.Free

  setup do
    Application.put_env(:stc, :event_log, {Stc.Backend.Postgres.EventLog, repo: Stc.Test.Repo})
    Application.put_env(:stc, :kv, {Stc.Backend.Postgres.KV, repo: Stc.Test.Repo})

    on_exit(fn ->
      Application.put_env(:stc, :event_log, {Stc.Backend.Memory.EventLog, []})
      Application.put_env(:stc, :kv, {Stc.Backend.Memory.KV, []})
    end)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Stc.Test.Repo)

    # shared mode so Task.async workers spawned by the parallel interpreter can use the same connection
    Ecto.Adapters.SQL.Sandbox.mode(Stc.Test.Repo, {:shared, self()})

    :ok
  end

  test "basic addition with postgres backend" do
    # (1 + 1) || (1 + 1) >>= fn [2, 2] -> 2 + (2 + 10) = 14
    program =
      Program.parallel([
        Program.run(TestAddTask, %{a: 1, b: 1}),
        Program.run(TestAddTask, %{a: 1, b: 1})
      ])
      |> bind(fn
        [2, 2] ->
          Program.run(TestAddTask, %{a: 2, b: 2 + 10})

        [r1, r2] ->
          Program.run(TestAddTask, %{a: r1, b: r2 + 1})
      end)

    assert {:ok, 14} == Interpreter.local(program, %{})
  end
end
