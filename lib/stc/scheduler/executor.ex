defmodule STC.Scheduler.Executor.State do
  defstruct [
    :agents,
    :workflow_id,
    :task_id,
    :task_spec,
    :attempt,
    :agent_ids,
    :space_id,
    :cluster_id,
    # store a reference to the pid
    :reply_buffer,

    :scheduler_id,
    # tunable timeouts for async tasks
    :startup_timeout_ref,
    :task_timeout_ref
  ]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          task_id: String.t(),
          task_spec: any(),
          agents: list(),
          scheduler_id: reference() | nil,
          reply_buffer: reference() | nil,
          attempt: integer(),
          agent_ids: list(),
          cluster_id: String.t() | nil,
          space_id: String.t() | nil,

          # tunable timeouts for async tasks
          startup_timeout_ref: reference() | nil,
          task_timeout_ref: reference() | nil
        }
end

defmodule STC.Scheduler.Executor do
  @moduledoc """
  Executes a task - can be used
  """
  use GenServer

  alias STC.Event
  alias STC.Event.Store

  def via(task_id) do
    {:via, Horde.Registry, {STC.ExecutorRegistry, "executor_#{task_id}"}}
  end

  def start_link(config) do
    # start under horde with a unique name
    GenServer.start_link(__MODULE__, config, name: via(config.task_id))
  end

  @impl true
  def init(config) do
    send(self(), :execute)
    {:ok, config}
  end

  @impl true
  def handle_info(:execute, state) do
    context = %{
      agents: state.agents,
      workflow_id: state.workflow_id,
      task_id: state.task_id,
      task_spec: state.task_spec,
      attempt: state.attempt,
      cluster_id: state.cluster_id,
      space_id: state.space_id,
      reply_buffer: state.reply_buffer
    }

    case state.task_spec.module.execute(state.task_spec, context) do
      {:ok, result} ->
        # for tasks that complete immediately
        emit_completion(state, result)
        {:stop, :normal, state}

      {:started, handle} ->
        # for async tasks
        # spawn a timeout

        startup_timeout_ref =
          if Map.has_key?(state.task_spec, :startup_timeout_ms) do
            Process.send_after(self(), :startup_timeout, state.task_spec.startup_timeout_ms)
          else
            nil
          end

        task_timeout_ref =
          if Map.has_key?(state.task_spec, :timeout_ms) do
            Process.send_after(self(), :task_timeout, state.task_spec.timeout_ms)
          else
            nil
          end

        state = %{
          state
          | startup_timeout_ref: startup_timeout_ref,
            task_timeout_ref: task_timeout_ref
        }

        emit_started(state, handle)
        {:noreply, state}

      {:error, reason} ->
        should_retry? =
          STC.Task.retriable?(state.task_spec.module, reason) &&
            state.attempt < state.max_attempts

        # try cleanup
        # cleanup probably needs to be an event too?
        state.task_spec.module.clean(state.task_spec, context)

        if should_retry? do
          emit_failure(state, reason, true)
          backoff = state.task_spec.retry_policy.backoff_ms
          Process.send_after(self(), :execute, backoff)
          {:noreply, Map.put(state, :attempt, state.attempt + 1)}
        else
          emit_failure(state, reason, false)
          {:stop, :normal, state}
        end
    end
  end

  def handle_info(:timeout, state) do
    emit_failure(state, :timeout, true)
    {:stop, :normal, state}
  end

  def handle_info(%Event.Completed{task_id: task_id}, state)
      when task_id == state.task_id do
    # cancel the timer
    Process.cancel_timer(state.timeout_ref)
    {:stop, :normal, state}
  end

  def handle_info(%Event.Failed{task_id: task_id}, state)
      when task_id == state.task_id do
    {:stop, :normal, state}
  end

  defp emit_started(state, handle) do
    event = %Event.Started{
      workflow_id: state.workflow_id,
      task_id: state.task_id,
      agent_ids: state.agent_ids,
      async_handle: handle,
      timestamp: DateTime.utc_now()
    }

    Store.append(event)
  end

  defp emit_completion(state, result) do
    event = %Event.Completed{
      workflow_id: state.workflow_id,
      task_id: state.task_id,
      agent_ids: state.agent_ids,
      result: result,
      attempt: state.attempt,
      timestamp: DateTime.utc_now()
    }

    Store.append(event)
  end

  defp emit_failure(state, reason, retriable) do
    event = %Event.Failed{
      workflow_id: state.workflow_id,
      task_id: state.task_id,
      agent_ids: state.agent_ids,
      reason: reason,
      retriable: retriable,
      attempt: state.attempt,
      timestamp: DateTime.utc_now()
    }

    Store.append(event)
  end
end
