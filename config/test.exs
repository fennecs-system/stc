import Config

# Tests always use in-memory backends so they are self-contained and require no
# external database. Each test starts its own supervised backend processes via
# start_supervised!/1, so there is no shared state between test cases.
config :stc,
  event_log: {Stc.Backend.Memory.EventLog, []},
  kv: {Stc.Backend.Memory.KV, []}

# Postgres repo used by postgres backend tests.
config :stc, ecto_repos: [Stc.Test.Repo]

config :stc, Stc.Test.Repo,
  username: "postgres",
  hostname: "localhost",
  database: "stc_test",
  priv: "priv/repo",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
