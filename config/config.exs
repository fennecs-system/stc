import Config

# Default to in-memory backends.
# Override in your application's config (e.g. config/prod.exs) to use Postgres:
#
#   config :stc,
#     event_log: {Stc.Backend.Postgres.EventLog, repo: MyApp.Repo},
#     kv:        {Stc.Backend.Postgres.KV,       repo: MyApp.Repo}
#
config :stc,
  event_log: {Stc.Backend.Memory.EventLog, []},
  kv: {Stc.Backend.Memory.KV, []}

import_config "#{config_env()}.exs"
