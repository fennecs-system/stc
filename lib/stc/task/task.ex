defmodule Stc.Task do
  @moduledoc """
  A generic task behaviour.

  Tasks are started by an agent. If the app dies mid-execution a transactional
  `clean/2` step can roll back any side-effects, after which the task is
  retried via `start/2`.

  For async tasks that return `{:started, handle}`, implement `resume/3` so a
  restarted executor can reconnect to in-flight work instead of launching a new
  instance. `resume/3` is called whenever a task has a `Started` event with no
  corresponding `Completed` — whether the task was still starting up or actively
  running at the time of the crash. The handle (e.g. a container ID) is sufficient
  to reconnect to either state. If `resume/3` is not implemented the executor falls
  back to `clean/2` followed by a fresh `start/2`.
  """

  alias Stc.Task.Result
  alias Stc.Task.Spec
  alias Stc.Task.Context

  @callback start(spec :: Spec.t(), context :: Context.t()) ::
              {:ok, Result.t()} | {:started, handle :: any()} | {:error, reason :: any()}

  @callback resume(spec :: Spec.t(), handle :: any(), context :: Context.t()) ::
              {:ok, Result.t()} | {:started, handle :: any()} | {:error, reason :: any()}

  @callback clean(spec :: Spec.t(), context :: Context.t()) :: :ok | {:error, reason :: any()}

  @callback retriable?(reason :: any()) :: boolean()

  @optional_callbacks [resume: 3, retriable?: 1, clean: 2]

  @doc "Returns true if the task module implements `resume/3`."
  @spec resumable?(module()) :: boolean()
  def resumable?(module), do: function_exported?(module, :resume, 3)

  @doc "Calls `clean/2` if implemented, otherwise no-ops."
  @spec clean(module(), Spec.t(), Context.t()) :: :ok | {:error, any()}
  def clean(module, spec, context) do
    if function_exported?(module, :clean, 2) do
      module.clean(spec, context)
    else
      :ok
    end
  end

  @doc "Returns true if `reason` is retriable according to the task module."
  @spec retriable?(module(), any()) :: boolean()
  def retriable?(module, reason) do
    if function_exported?(module, :retriable?, 1) do
      module.retriable?(reason)
    else
      false
    end
  end
end
