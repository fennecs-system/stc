defmodule Stc.Supervisor do
  @moduledoc """
  Top-level supervisor for Stc.

  ## Usage

      # In your Application.start/2:
      children = [
        {Stc, repo: MyApp.Repo, schedulers: [
          [id: "primary", algorithm: MyApp.SchedulingAlgorithm, level: :local]
        ]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

    - `:repo` — Ecto repo module to use for the Postgres backends. If omitted
      the application config is used as-is (useful when backends are already
      configured, e.g. in tests with in-memory backends).

    - `:schedulers` — list of keyword lists, each forwarded to
      `Stc.Scheduler.start_link/1`. Each entry must include `:id` and
      `:algorithm`.

  ## What gets started

  1. Backend processes (only for in-memory backends; Postgres backends are
     stateless and need no process).
  2. `Horde.Registry` for scheduler and executor name registration.
  3. `Stc.Interpreter.Distributed` — the walker that advances workflows as
     tasks complete.
  4. One `Stc.Scheduler` per entry in `:schedulers`.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    if repo = Keyword.get(opts, :repo) do
      Application.put_env(:stc, :event_log, {Stc.Backend.Postgres.EventLog, repo: repo})
      Application.put_env(:stc, :kv, {Stc.Backend.Postgres.KV, repo: repo})
    end

    schedulers = Keyword.get(opts, :schedulers, [])

    children =
      Stc.Backend.child_specs() ++
        [
          {Horde.Registry, name: Stc.SchedulerRegistry, keys: :unique, members: :auto},
          {Horde.Registry, name: Stc.ExecutorRegistry, keys: :unique, members: :auto},
          Stc.Interpreter.Distributed
        ] ++
        Enum.map(schedulers, fn sched_opts -> {Stc.Scheduler, sched_opts} end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
