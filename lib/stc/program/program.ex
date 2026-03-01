defmodule Stc.Program do
  @moduledoc """
  A program is a sequence of operations to be executed by the Stc
  """

  import Stc.Free

  alias Stc.Op
  alias Stc.Task.Policy
  alias Stc.Task.Policy.Retry

  def run(module, payload, task_id \\ nil, opts \\ [])

  def run(module, payload, opts, []) when is_list(opts) do
    run(module, payload, nil, opts)
  end

  def run(module, payload, nil, opts) do
    {:free,
     %Op.Run{
       task_id: Ecto.UUID.generate(),
       module: module,
       payload: payload,
       cluster_affinity: Keyword.get(opts, :cluster_affinity, nil),
       space_affinity: Keyword.get(opts, :space_affinity, nil),
       agent_affinity: Keyword.get(opts, :agent_affinity, nil),
       store: Keyword.get(opts, :store, false),
       policies: build_policies(opts)
     }, fn result -> pure(result) end}
  end

  def run(module, payload, task_id, opts) do
    {:free,
     %Op.Run{
       task_id: task_id,
       module: module,
       payload: payload,
       cluster_affinity: Keyword.get(opts, :cluster_affinity, nil),
       space_affinity: Keyword.get(opts, :space_affinity, nil),
       agent_affinity: Keyword.get(opts, :agent_affinity, nil),
       store: Keyword.get(opts, :store, false),
       policies: build_policies(opts)
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

  @spec build_policies(keyword()) :: Policy.t()
  defp build_policies(opts) do
    %Policy{
      admit: Keyword.get(opts, :admit_policies, []),
      retry: Keyword.get(opts, :retry_policy, %Retry{}),
      continue: Keyword.get(opts, :continue_policies, [])
    }
  end
end
