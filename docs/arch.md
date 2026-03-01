## stc 

### Design 

Some of this stuff was influenced by things we were working on, and stuff we need from oban - 

- Free monad tasks definition 
- Tasks get submitted to an interpreter which walks the monad program
- Walking the program emits start events which can be picked up by schedulers
- Running the tasks, and completing it emits events which can be used to keep walking the program, retry tasks etc
- Pluggable scheduler behaviour
- In memory or postgres backed event and program stores for compatability with other elixir phoenix apps
- Simple local program evaluator for testing purposes 
- Backed by horde for distribution 

### Core components 

- Event store
- Program store
- Scheduler
- Executor
- Interpreter 

Programs get submitted to an interpreter 
-> interpreter walks the the program emitting events, stores the program in the program store
-> events picked up by scheduler 
-> scheduler can assign tasks to `agents` basically just either a remote elixir process, a local async task, a task on another elixir node, something that runs over a websocket etc - flexible as long as they can reply to the scheduler via the buffer or the process directly
-> 

### Liveness checks 

Tasks can fail for multiple reasons. Eg the task itself dies on the agent, or the agent dies entirely.

```
┌──────────────────┬────────────────────────────────┬─────────────────────────────────────────┐
│                  │         Liveness check         │           Agent health check            │
├──────────────────┼────────────────────────────────┼─────────────────────────────────────────┤
│ Probe source     │ task_module.running?/3         │ refresh_agent_pool diff                 │
├──────────────────┼────────────────────────────────┼─────────────────────────────────────────┤
│ Failure tracking │ window + threshold on executor │ window + threshold on scheduler         │
├──────────────────┼────────────────────────────────┼─────────────────────────────────────────┤
│ Actor            │ executor                       │ scheduler                               │
├──────────────────┼────────────────────────────────┼─────────────────────────────────────────┤
│ Scope            │ is the work itself alive?      │ is the infrastructure running it alive? │
└──────────────────┴────────────────────────────────┴─────────────────────────────────────────┘
```