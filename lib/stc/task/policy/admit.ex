defmodule Stc.Task.Policy.Admit do
  @moduledoc """
  Behaviour for `admission` policies evaluated by the scheduler before a task is dispatched.

  Admission policies are structs declared in `admit_policies: [...]` on `Program.run/4`.
  They flow through `Op.Run` and `Event.Ready` to the scheduler, which evaluates them in
  order before spawning an executor.

  Admit policies must return :ok, or {:reject, reason}

  If a policy returns `{:reject, reason}`, the task is buffered as a `pending` task and
  retried on the next scheduler tick. This is equivalent to when agents have no capacity.

  This means a rejected task will be retried automatically, so policies that reserve a shared
  resource (e.g. budget) will naturally unblock once other tasks complete and release their
  reservations.

  ## Example

      defmodule BudgetPolicy do
        @behaviour Stc.Task.Policy.Admit
        defstruct [:max_spend]

        @impl true
        def admit(%__MODULE__{max_spend: max}, context) do
          case BudgetService.try_reserve(context.workflow_id, max) do
            :ok -> :ok
            {:error, :insufficient} -> {:reject, :insufficient_budget}
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

  Return `:ok` to allow execution, or `{:reject, reason}` to defer.
  """
  @callback admit(policy :: struct(), context :: Context.t()) ::
              :ok | {:reject, reason :: term()}
end
