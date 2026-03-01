## todos

- cancel / stop - stop a task mid execution
  - executor receives `:cancel`, calls `Task.clean/3`, emits `Cancelled` event
  - scheduler needs `workflow_tasks: %{workflow_id => [task_id]}` to find active tasks by workflow

- [done] can continue, retry, admit policies 

- move semantics - move task execution - eg a node dies in this space - lets move it, or gets requested to move
  - `reconcile_stale_agents` detects dead agents; moving = cancel executor for their tasks,
    re-emit `Ready` events; `resume/3` handles reconnecting to in-flight work

- run a task for x time (duration_ms on Spec, distinct from timeout_ms which means failure)
  - executor fires `:duration_elapsed` after duration_ms → sends stop signal to agent
  - agent stops gracefully and replies `{:result, result}`

- [done] store tasks - like a nix store but for tasks; opt-in via `store: true` on `Op.Run`
  - task_id is derived as hash of `{module, payload}` — content-addressed identity
  - before emitting `Ready`, distributed walker checks for a store entry:
      `"stc:store:{task_id}"` → `{canonical_task_id, result}`
    - entry exists + verify passes → emit synthetic `Completed` immediately (skip execution)
    - entry exists + verify fails → stale, re-run
    - in-flight (no entry, locked) → register workflow as waiter in `"stc:store_waiters:{task_id}"`
    - not found → claim with `put_if_absent`, emit `Ready` normally
  - on completion: write store entry, fan out synthetic `Completed` to all waiters
  - optional `verify/2` callback on `Task` behaviour: given spec + cached result, prove still valid
    (eg. check file exists and checksum matches); re-runs task if verification fails
  - requires `put_if_absent` on `Backend.KV` behaviour
    (in-memory: ETS `:insert_new`, postgres: `INSERT ... ON CONFLICT DO NOTHING`)

- tracing back cleanup - eg suppose the workflow is download => start container => stop => start =>
  delete. We can walk back all the `.clean` steps on each task.
  - scan event log for `Completed` events for workflow (ordered by timestamp), reverse, call
    `Task.clean/3` on each; `Ready` events carry module+payload needed to reconstruct the spec

- who initiates cleanup tasks? lookup via horde - cancel it.
