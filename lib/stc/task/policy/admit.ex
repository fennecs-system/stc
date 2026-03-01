defmodule Stc.Task.Policy.Admit do
  @moduledoc """
  Behaviour for `admission` policies evaluated by the scheduler before a task is dispatched.

  Admission policies are structs declared in `admit_policies: [...]` on `Program.run/4`.
  They flow through `Op.Run` and `Event.Ready` to the scheduler, which evaluates them in
  order before spawning an executor.

  Admit policies must return `:ok`, `{:pending, conditions}`, or `{:reject, reason}`.

  - `:ok` — task is admitted and an executor is spawned.
  - `{:pending, conditions}` — transient resource constraint (e.g. budget quota exhausted,
    no capacity on a downstream system). The scheduler emits an `Event.Pending` with the
    given `conditions` and retries on the next tick. Use this for states that resolve
    naturally as other tasks complete.
  - `{:reject, reason}` — permanent denial. Currently also emits `Event.Pending` (with
    `conditions: {:rejected, reason}`) and retries, so the task remains unschedulable until
    the policy changes. A future `Event.Rejected` terminal event will be emitted instead.

  ## Example

      defmodule BudgetPolicy do
        @behaviour Stc.Task.Policy.Admit
        defstruct [:max_spend]

        @impl true
        def admit(%__MODULE__{max_spend: max}, context) do
          case BudgetService.try_reserve(context.workflow_id, max) do
            :ok -> :ok
            {:error, :insufficient} -> {:pending, :insufficient_budget}
          end
        end
      end

      Program.run(DownloadDataset, payload,
        admit_policies: [%BudgetPolicy{max_spend: 100}]
      )
  """

  alias Stc.Task.Context

  @type t :: term()

  @doc """
  Called by the scheduler before dispatching a task.

  Return `:ok` to allow execution, `{:pending, conditions}` to defer due to a transient
  resource constraint, or `{:reject, reason}` for a permanent denial.
  """
  @callback admit(policy :: struct(), context :: Context.t()) ::
              :ok | {:pending, conditions :: term()} | {:reject, reason :: term()}
end
