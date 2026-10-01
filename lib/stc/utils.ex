defmodule Stc.Utils do
  @moduledoc """
  Operational utilities for STC deployments.

  These functions are intended to be called by host applications — from a
  scheduled job (Oban, Quantum), an admin LiveView, or a one-off IEx session.
  They require the Postgres backend and a running Ecto repo.
  """

  import Ecto.Query

  alias Stc.Backend.Postgres.EventRecord
  alias Stc.Program.Store, as: ProgramStore

  # Used only to identify tasks eligible for intermediate event cleanup (pass 1).
  # Failed{retriable: true/false} cannot be distinguished without deserialising
  # the payload, so we only trigger on Completed. Pass 2 handles full workflow
  # cleanup regardless of individual task event types.
  @terminal_type Atom.to_string(Stc.Event.Completed)

  # Events that are safe to delete once a task has a Completed event.
  @purgeable_types Enum.map(
                     [
                       Stc.Event.Ready,
                       Stc.Event.Started,
                       Stc.Event.Pending,
                       Stc.Event.Failed,
                       Stc.Event.Preempted
                     ],
                     &Atom.to_string/1
                   )

  @doc """
  Compacts the STC Postgres event log.

  Two passes are run:

  1. **Intermediate events** — for every task that has a `Completed` event,
     delete its `Ready`, `Started`, `Pending`, `Failed`, and `Preempted` events.
     The `Completed` event itself is kept as the terminal record.

  2. **Completed workflow events** — for every workflow whose program tree is
     no longer in the program store (completed or stopped), delete all its
     events including `Completed`. Once the walker has consumed and advanced
     past those events and the program is gone, nothing needs them anymore.
     Subject to `min_age_hours` so recently finished workflows are left alone
     during any in-flight scheduler cursor catch-up.

  Returns `{:ok, %{intermediate: n, workflow: n}}` with the deletion counts,
  or `{:error, reason}` if the repo is misconfigured or a query fails.

  ## Options

    - `:repo` — Ecto repo module (required).
    - `:min_age_hours` — only touch events older than this many hours
      (default: `1`). Protects events that active schedulers may not yet
      have consumed.
    - `:dry_run` — if `true`, return counts without deleting anything
      (default: `false`).

  ## Example

      Stc.Utils.compact_events(repo: MyApp.Repo)
      Stc.Utils.compact_events(repo: MyApp.Repo, dry_run: true, min_age_hours: 24)

  """
  @spec compact_events(keyword()) ::
          {:ok, %{intermediate: non_neg_integer(), workflow: non_neg_integer()}}
          | {:error, term()}
  def compact_events(opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)
    min_age_hours = Keyword.get(opts, :min_age_hours, 1)
    dry_run? = Keyword.get(opts, :dry_run, false)
    cutoff = DateTime.add(DateTime.utc_now(), -min_age_hours * 3600, :second)

    with {:ok, intermediate} <- compact_intermediate_events(repo, cutoff, dry_run?),
         {:ok, workflow} <- compact_workflow_events(repo, cutoff, dry_run?) do
      {:ok, %{intermediate: intermediate, workflow: workflow}}
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec compact_intermediate_events(module(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp compact_intermediate_events(repo, cutoff, dry_run?) do
    completed_task_ids =
      from(e in EventRecord,
        where: e.type == @terminal_type and e.inserted_at < ^cutoff and not is_nil(e.task_id),
        select: e.task_id,
        distinct: true
      )

    query =
      from(e in EventRecord,
        where: e.task_id in subquery(completed_task_ids) and e.type in @purgeable_types
      )

    count = if dry_run?, do: repo.aggregate(query, :count), else: elem(repo.delete_all(query), 0)
    {:ok, count}
  end

  @spec compact_workflow_events(module(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp compact_workflow_events(repo, cutoff, dry_run?) do
    active_ids =
      case ProgramStore.list_workflow_ids() do
        {:ok, ids} -> ids
        _ -> :error
      end

    case active_ids do
      :error ->
        {:ok, 0}

      [] ->
        # Program store is empty — could mean all done, or STC isn't running.
        # Don't delete anything; require at least one active workflow to be
        # present before trusting the list is authoritative.
        {:ok, 0}

      ids ->
        query =
          from(e in EventRecord,
            where:
              not is_nil(e.workflow_id) and
                e.workflow_id not in ^ids and
                e.inserted_at < ^cutoff
          )

        count =
          if dry_run?, do: repo.aggregate(query, :count), else: elem(repo.delete_all(query), 0)

        {:ok, count}
    end
  end
end
