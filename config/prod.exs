import Config

# Override with Postgres backends in production:
#
#   config :stc,
#     event_log: {Stc.Backend.Postgres.EventLog, repo: MyApp.Repo},
#     kv:        {Stc.Backend.Postgres.KV,       repo: MyApp.Repo}
