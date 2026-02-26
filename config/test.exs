import Config

# Tests always use in-memory backends so they are self-contained and require no
# external database. Each test starts its own supervised backend processes via
# start_supervised!/1, so there is no shared state between test cases.
config :stc,
  event_log: {Stc.Backend.Memory.EventLog, []},
  kv: {Stc.Backend.Memory.KV, []}
