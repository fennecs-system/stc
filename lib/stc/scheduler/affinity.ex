defmodule Stc.Scheduler.Affinity do
  @moduledoc """
  Scheduler-level admission gates for incoming events.

  ## Routing affinity

  `matches_scheduler?/2` checks whether a `Ready` or `Pending` event should be
  handled by a given scheduler instance, based on three dimensions:

  - `scheduler_affinity` (tags) - a list of atoms, and a task with tags is only accepted by a scheduler
    that shares at least one tag. A task with no tags is accepted by any scheduler which doesnt have tags.
    An untagged scheduler will not pick up tagged tasks.
  - `space_affinity` - tasks with a space id must match `State.space_id` to be scheduled on a scheduler with a space id; nil on either side means any.
  - `cluster_affinity` - tasks with a cluster id must match `State.cluster_id` to be scheduled on a scheduler with a cluster id; nil on either side means any.

  ## Admit policies

  `check_admit_policies/3` runs the task's admit-policy chain against the selected
  agents. Each policy returns `:ok`, `{:pending, conditions}`, or `{:reject, reason}`.
  The first non-ok result short-circuits the chain.
  """

  alias Stc.Scheduler.State
  alias Stc.Task.Context
  alias Stc.Task.Spec

  require Logger

  @doc "Returns true if the event's affinity dimensions match this scheduler."
  @spec matches_scheduler?(
          Stc.Event.Ready.t() | Stc.Event.Pending.t(),
          State.t()
        ) :: boolean()
  def matches_scheduler?(
        %{scheduler_affinity: sa, space_affinity: spa, cluster_affinity: ca},
        state
      ) do
    tags_match?(sa, state.tags) and
      space_match?(spa, state.space_id) and
      cluster_match?(ca, state.cluster_id)
  end

  @doc "Runs the admit-policy chain for an event against the selected agents."
  @spec check_admit_policies(Stc.Event.Ready.t(), [Stc.Agent.t()], State.t()) ::
          :ok | {:error, :rejected | {:pending, term()}}
  def check_admit_policies(%Stc.Event.Ready{policies: nil}, _agents, _state), do: :ok
  def check_admit_policies(%Stc.Event.Ready{policies: %{admit: []}}, _agents, _state), do: :ok

  def check_admit_policies(
        %Stc.Event.Ready{policies: %{admit: policies}} = event,
        agents,
        state
      ) do
    context = %Context{
      workflow_id: event.workflow_id,
      task_id: event.task_id,
      agents: agents,
      task_spec: Spec.new(event.module, event.payload, policies: event.policies),
      attempt: 1,
      cluster_id: nil,
      space_id: nil,
      reply_buffer: state.reply_buffer
    }

    Enum.reduce_while(policies, :ok, fn policy, _ ->
      case policy.__struct__.admit(policy, context) do
        :ok ->
          {:cont, :ok}

        {:pending, conditions} ->
          {:halt, {:error, {:pending, conditions}}}

        {:reject, reason} ->
          Logger.warning(
            "Task #{event.task_id} rejected by #{inspect(policy.__struct__)}: #{inspect(reason)}"
          )

          {:halt, {:error, :rejected}}
      end
    end)
  end

  #
  ## Private helpers
  #

  defp tags_match?(nil, _), do: true
  defp tags_match?(_, []), do: false
  defp tags_match?(task_tags, scheduler_tags), do: Enum.any?(task_tags, &(&1 in scheduler_tags))

  defp space_match?(nil, _), do: true
  defp space_match?(_, nil), do: false
  defp space_match?(a, b), do: a == b

  defp cluster_match?(nil, _), do: true
  defp cluster_match?(_, nil), do: false
  defp cluster_match?(a, b), do: a == b
end
