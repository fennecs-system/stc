defmodule Stc.Task.Policy.Continue do
  @moduledoc """
  Behaviour for runtime policies evaluated by the scheduler each tick while a task is running.

  Continue policies are for costs or conditions that can't be fully known at admission time;
  for example, egress charges that accumulate during execution, or budget changes caused by
  other jobs failing mid-flight.

  If any policy returns `{:cancel, reason}`, the scheduler cancels the executor (calling
  `Task.clean/3` and emitting a `Cancelled` event). Most tasks won't need continue policies;
  checks that can be made upfront belong in an `Stc.Task.Policy.Admit` policy instead.

  ## Example

      defmodule EgressPolicy do
        @behaviour Stc.Task.Policy.Continue
        defstruct [:max_gb]

        @impl true
        def continue(%__MODULE__{max_gb: max}, context) do
          case EgressMonitor.current_gb(context.task_id) do
            gb when gb <= max -> :ok
            _ -> {:cancel, :egress_limit_exceeded}
          end
        end
      end

      Program.run(UploadTask, payload,
        continue_policies: [%EgressPolicy{max_gb: 10}]
      )
  """

  alias Stc.Task.Context

  @type t :: term()

  @doc """
  Called by the executor on each check while the task is running.

  Return `:ok` to allow execution to continue, or `{:cancel, reason}` to cancel.
  """
  @callback continue(policy :: struct(), context :: Context.t()) ::
              :ok | {:cancel, reason :: term()}

  @doc """
  How often this policy should be checked, in milliseconds. Defaults to 1000ms - :timer.seconds(1).

  Expensive policies (e.g. external service calls) should return a larger value.
  Each policy is scheduled independently, so a slow policy does not affect the
  check rate of faster ones.
  """
  @callback check_interval_ms(policy :: struct()) :: pos_integer()

  @optional_callbacks [check_interval_ms: 1]

  @doc "Returns the check interval for `policy`, falling back to 1000ms if not implemented."
  @spec check_interval_ms(struct()) :: pos_integer()
  def check_interval_ms(policy) do
    module = policy.__struct__

    if function_exported?(module, :check_interval_ms, 1) do
      module.check_interval_ms(policy)
    else
      1_000
    end
  end
end
