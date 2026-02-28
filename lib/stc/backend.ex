defmodule Stc.Backend do
  @moduledoc """
  Reads the application config and returns the configured backend modules.

  ## Configuration

      # config/config.exs  (memory — default, no extra deps)
      config :stc,
        event_log: {Stc.Backend.Memory.EventLog, []},
        kv:        {Stc.Backend.Memory.KV, []}

      # config/prod.exs  (postgres)
      config :stc,
        event_log: {Stc.Backend.Postgres.EventLog, repo: MyApp.Repo},
        kv:        {Stc.Backend.Postgres.KV,       repo: MyApp.Repo}

  The `{module, opts}` tuple matches the standard `{module, keyword}` child-spec
  pattern — stateful backends (Memory) implement `start_link/1` and can be placed
  directly in a supervision tree. Stateless backends (Postgres) delegate to an
  existing Ecto repo and require no extra process.
  """

  @doc "Returns the configured `Stc.Backend.EventLog` implementation module."
  @spec event_log() :: module()
  def event_log do
    {mod, _opts} = Application.fetch_env!(:stc, :event_log)
    mod
  end

  @doc "Returns the configured `Stc.Backend.KV` implementation module."
  @spec kv() :: module()
  def kv do
    {mod, _opts} = Application.fetch_env!(:stc, :kv)
    mod
  end

  @doc """
  Returns child specs for any backends that need to be supervised.

  Memory backends start a GenServer process; Postgres backends are stateless and
  return an empty list. Call this from your application's supervision tree:

      children = Stc.Backend.child_specs() ++ [...]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    [{_el_mod, el_opts}, {_kv_mod, kv_opts}] =
      [
        Application.fetch_env!(:stc, :event_log),
        Application.fetch_env!(:stc, :kv)
      ]

    [
      maybe_child_spec(event_log(), el_opts),
      maybe_child_spec(kv(), kv_opts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec maybe_child_spec(module(), keyword()) :: Supervisor.child_spec() | nil
  defp maybe_child_spec(mod, opts) do
    if function_exported?(mod, :start_link, 1) do
      %{id: mod, start: {mod, :start_link, [opts]}}
    else
      nil
    end
  end
end
