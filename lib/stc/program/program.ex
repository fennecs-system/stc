defmodule Stc.Program do
  @moduledoc """
  A program is a sequence of operations to be executed by the Stc
  """

  alias Stc.Op
  import Stc.Free

  def run(module, payload, task_id \\ nil, opts \\ [])

  def run(module, payload, nil, opts) do
    {:free,
     %Op.Run{
       task_id: Ecto.UUID.generate() |> dbg(),
       module: module,
       payload: payload,
       # map opts to fields
       cluster_affinity: Keyword.get(opts, :cluster_affinity, nil),
       space_affinity: Keyword.get(opts, :space_affinity, nil),
       agent_affinity: Keyword.get(opts, :agent_affinity, nil)
     }, fn result -> pure(result) end}
  end

  def run(module, payload, task_id, opts) do
    {:free,
     %Op.Run{
       task_id: task_id,
       module: module,
       payload: payload,
       # map opts to fields
       cluster_affinity: Keyword.get(opts, :cluster_affinity, nil),
       space_affinity: Keyword.get(opts, :space_affinity, nil),
       agent_affinity: Keyword.get(opts, :agent_affinity, nil)
     }, fn result -> pure(result) end}
  end

  def sequence(programs) do
    {:free, %Op.Sequence{programs: programs}, fn results -> pure(results) end}
  end

  def parallel(programs) do
    {:free, %Op.Parallel{programs: programs}, fn results -> pure(results) end}
  end

  def emit_event(event) do
    {:free, %Op.EmitEvent{event: event, continuation: fn -> pure(:ok) end},
     fn result -> result end}
  end

  def on_failure(task_id, handler) do
    {:free, %Op.OnFailure{task_id: task_id, handler: handler}, fn result -> pure(result) end}
  end
end
