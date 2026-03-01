defmodule Stc.Scheduler.State do
  @moduledoc """
  The state of a `Stc.Scheduler` instance.

  ## Event consumption model

  The scheduler maintains a `event_cursor` — an opaque position in the `EventLog` —
  and advances it each tick by calling `Stc.Event.Store.fetch/2`. Events that could
  not be acted on immediately (e.g. `Ready` events with no available agents) are kept
  in `pending_ready` and retried on the next tick. All other event types are consumed
  once and discarded from in-memory state.

  ## Affinity routing

  Three fields narrow which `Ready` events this scheduler will handle:

  - `tags` — matched against `Event.Ready.scheduler_affinity`. A task with no
    `scheduler_affinity` (nil) is accepted by any scheduler. A task *with* tags is
    only accepted by a scheduler that shares at least one tag. An **untagged scheduler**
    (`tags: []`) will **not** pick up tagged tasks — it only handles untagged ones.
  - `space_id` — matched exactly against `Event.Ready.space_affinity`. nil on the task
    means "any space"; nil on the scheduler means "space unknown, reject space-pinned tasks".
  - `cluster_id` — same exact-match semantics as `space_id`.

  All three must match for the scheduler to act on an event. Existing schedulers and
  tasks that leave all affinity fields nil continue to match each other unchanged.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          # :local | :space | :cluster
          level: atom(),
          agent_pool: [Stc.Agent.t()],
          # Agents temporarily inactive (e.g. brief timeout, heartbeat missed).
          stale_agent_pool: [Stc.Agent.t()],
          algorithm: module(),
          # agent_id => [task_id]
          agent_tasks: %{String.t() => [String.t()]},
          # task_id => lock term acquired via Event.Store.try_lock/3
          task_locks: %{String.t() => term()},
          # task_id => executor pid
          active_tasks: %{String.t() => pid()},
          event_loop_ref: reference() | nil,
          # Cursor into the EventLog; advances forward-only each tick.
          event_cursor: Stc.Backend.EventLog.cursor(),
          # Ready events that couldn't be scheduled (no capacity); retried each tick.
          pending_ready: [Stc.Event.Ready.t()],
          # pid of this scheduler's ReplyBuffer
          reply_buffer: pid(),
          # time in ms of tick rate - defaults to 1 sec
          scheduler_tick_rate_ms: integer(),
          # Affinity dimensions for routing Ready events to this scheduler.
          tags: [atom()],
          space_id: String.t() | nil,
          cluster_id: String.t() | nil
        }

  defstruct [
    :id,
    :level,
    :agent_pool,
    :stale_agent_pool,
    :algorithm,
    :agent_tasks,
    :task_locks,
    :active_tasks,
    :event_loop_ref,
    :event_cursor,
    :reply_buffer,
    :scheduler_tick_rate_ms,
    :space_id,
    :cluster_id,
    pending_ready: [],
    tags: []
  ]
end
