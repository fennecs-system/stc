# stc

## About

STC is wip library for declarative programmatic workflows in elixir using a simple monad like syntax:

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

