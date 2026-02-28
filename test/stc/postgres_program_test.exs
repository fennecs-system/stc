defmodule Stc.PostgresProgramTest do
  use ExUnit.Case, async: false

  import Stc.Free

  alias Ecto.Adapters.SQL.Sandbox
  alias Stc.Backend.Memory
  alias Stc.Backend.Postgres
  alias Stc.Interpreter
  alias Stc.Program
  alias Stc.Task.TestAddTask
  alias Stc.Test.Repo

  setup do
    Application.put_env(:stc, :event_log, {Postgres.EventLog, repo: Repo})
    Application.put_env(:stc, :kv, {Postgres.KV, repo: Repo})

    on_exit(fn ->
      Application.put_env(:stc, :event_log, {Memory.EventLog, []})
      Application.put_env(:stc, :kv, {Memory.KV, []})
    end)

    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

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
