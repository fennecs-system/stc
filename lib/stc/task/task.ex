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

  alias Stc.Task.Context
  alias Stc.Task.Result
  alias Stc.Task.Spec

  @callback start(spec :: Spec.t(), context :: Context.t()) ::
              {:ok, Result.t()} | {:started, handle :: any()} | {:error, reason :: any()}

  @callback resume(spec :: Spec.t(), handle :: any(), context :: Context.t()) ::
              {:ok, Result.t()} | {:started, handle :: any()} | {:error, reason :: any()}

  @callback clean(spec :: Spec.t(), context :: Context.t()) :: :ok | {:error, reason :: any()}

  @callback retriable?(reason :: any()) :: boolean()

  @doc """
  Liveness probe for async tasks.

  Called periodically by the executor while the task is running. Return `:ok`
  if the task is still alive, or `{:not_running, reason}` if it appears dead
  (e.g. the remote container has stopped, the WebSocket is closed, etc.).

  If not implemented the executor skips liveness checking regardless of the
  `liveness_check` setting on the spec.
  """
  @callback running?(spec :: Spec.t(), handle :: any(), context :: Context.t()) ::
              :ok | {:not_running, reason :: any()}

  @optional_callbacks [resume: 3, retriable?: 1, clean: 2, running?: 3]

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

  @doc "Calls `running?/3` if implemented, otherwise returns `:ok`."
  @spec running?(module(), Spec.t(), any(), Context.t()) :: :ok | {:not_running, any()}
  def running?(module, spec, handle, context) do
    if function_exported?(module, :running?, 3) do
      module.running?(spec, handle, context)
    else
      :ok
    end
  end
end
