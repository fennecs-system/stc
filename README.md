# stc

## About

Stc is wip library for declarative programmatic workflows in elixir using a simple monad like syntax:

```elixir
program =
  Program.parallel([
    Program.run(TestAddTask, %{a: 1, b: 1}, :add1),
    Program.run(TestAddTask, %{a: 1, b: 1}, :add2)
  ])
  |> bind(fn
    [2, 2] ->
      Program.run(
        TestAddTask,
        %{a: 2, b: 2 + 10},
        :add_3
      )

    [r1, r2] ->
      Program.run(
        TestAddTask,
        %{a: r1, b: r2 + 1},
        :add_3
      )
  end)

Interpreter.distributed(program, %{workflow_id: "test_workflow_1"})
```
Programs are interpreted and execution is performed by an agent/worker driven by a scheduler. 

The goals are:
- monad like syntax for entire workflows
- pluggable agent and scheduler types, with affinity options, 
- an event system for tracing and possibly state reconcilliation or cleanup
- distributed first design (runs in a cluster with horde)
- reliability - survive app restarts/cluster rebalancing


## Setup

### 1. Add a migration

```elixir
defmodule MyApp.Repo.Migrations.AddStcTables do
  use Ecto.Migration
  def up, do: Stc.Migrations.up()
  def down, do: Stc.Migrations.down()
end
```

Run `mix ecto.migrate` as normal.

### 2. Add to your supervision tree

```elixir
children = [
  MyApp.Repo,
  {Stc, repo: MyApp.Repo, schedulers: [
    [id: "primary", algorithm: MyApp.SchedulingAlgorithm, level: :local]
  ]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### 3. Write a task

```elixir
defmodule MyApp.MyTask do
  @behaviour Stc.Task

  alias Stc.Task.Result

  @impl true
  def start(%Stc.Task.Spec{payload: payload}, _context) do
    {:ok, Result.to_result(woof(payload))}
  end
end
```

### 4. Write a workflow / program

```elixir
import Stc.Free

program =
  Program.parallel([
    Program.run(MyApp.MyTask, %{input: "a"}),
    Program.run(MyApp.MyTask, %{input: "b"})
  ])
  |> bind(fn [r1, r2] ->
    Program.run(MyApp.MyTask, %{input: r1 <> r2})
  end)

Interpreter.distributed(program, %{workflow_id: "my-workflow-1"})
```

`bind/2` threads the results of one step into the next. Use `Program.sequence/1` for ordered steps or `unfold/2` to loop until a condition is met.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `stc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:stc, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/stc>.

