defmodule STC.Scheduler.Executor do
  @moduledoc """
  Executes a task - can be used
  """
  use GenServer

  alias STC.Event
  alias STC.Event.Store

  defstruct [
    :name,
    :agents,
    :workflow_id,
    :task_id,
    :module,
    :attempt,
    :cluster_id,
    :space_id,
    # store a reference to the pid
    :reply_buffer
  ]

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
          backoff = state.task_spec.retry_policy.backoff_ms
          Process.send_after(self(), :execute, backoff)
          {:noreply, Map.put(state, :attempt, state.attempt + 1)}
        else
          emit_failure(state, reason, false)
          {:stop, :normal, state}
        end
    end
  end

  def handle_info(%Event.Completed{task_id: task_id}, state)
      when task_id == state.task_id do
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
