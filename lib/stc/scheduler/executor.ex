defmodule Stc.Scheduler.Executor.State do
  @moduledoc false

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          task_id: String.t(),
          task_spec: Stc.Task.Spec.t(),
          agents: [Stc.Agent.t()],
          agent_ids: [String.t()],
          scheduler_id: String.t(),
          reply_buffer: pid(),
          attempt: pos_integer(),
          cluster_id: String.t() | nil,
          space_id: String.t() | nil,
          startup_timeout_ref: reference() | nil,
          task_timeout_ref: reference() | nil
        }

  defstruct [
    :workflow_id,
    :task_id,
    :task_spec,
    :agents,
    :agent_ids,
    :scheduler_id,
    :reply_buffer,
    :attempt,
    :cluster_id,
    :space_id,
    startup_timeout_ref: nil,
    task_timeout_ref: nil
  ]
end

defmodule Stc.Scheduler.Executor do
  @moduledoc """
  Executes a single task instance.

  ## Synchronous tasks

  When `module.start/2` returns `{:ok, result}`, the executor emits `Completed` and
  stops immediately.

  ## Async tasks

  When `module.start/2` returns `{:started, handle}`, the executor:

  1. Registers itself with the `ReplyBuffer` for its `task_id`.
  2. Emits `Started` with the async handle (so the agent knows how to signal back).
  3. Waits for reply messages forwarded by the `ReplyBuffer`:
     - `:started_tick` — agent confirmed it started; cancels the startup timeout.
     - `{:result, result}` — agent finished; emits `Completed` and stops.
     - `{:failed, reason}` — agent failed; triggers retry/failure logic.

  The direct path is also supported: an agent may send `{:started_tick, task_id}`
  directly to the executor's registered Horde name (`Executor.via(task_id)`), which
  is equivalent to the buffered path.

  ## Timeouts

  - `startup_timeout_ms` — if set, fires if no `:started_tick` is received within
    the window. The task is marked as failed with reason `:startup_timeout`.
  - `timeout_ms` — if set, fires if the task does not complete within the window
    (measured from when the executor starts). Reason: `:task_timeout`.
  """

  use GenServer

  require Logger

  alias Stc.Event
  alias Stc.Event.Store
  alias Stc.ReplyBuffer
  alias Stc.Scheduler.Executor.State
  alias Stc.Task.Context
  alias Stc.Task.Spec

  # api

  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(task_id) do
    {:via, Horde.Registry, {Stc.ExecutorRegistry, "executor_#{task_id}"}}
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, struct!(State, config), name: via(config.task_id))
  end

  @impl GenServer
  def init(%State{} = state) do
    send(self(), :start)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:start, %State{} = state) do
    context = to_context(state)

    case state.task_spec.module.start(state.task_spec, context) do
      {:ok, result} ->
        emit_completion(state, result)
        {:stop, :normal, state}

      {:started, handle} ->
        state = maybe_spawn_timeouts(state)
        ReplyBuffer.register_executor(state.reply_buffer, state.task_id, self())
        emit_started(state, handle)
        {:noreply, state}

      {:error, reason} ->
        handle_failure(state, reason, context)
    end
  end

  @impl GenServer
  def handle_info({:started_tick, task_id}, %State{task_id: task_id} = state) do
    {:noreply, cancel_startup_timeout(state)}
  end

  @impl GenServer
  def handle_info({:reply, task_id, _agent_id, :started_tick}, %State{task_id: task_id} = state) do
    {:noreply, cancel_startup_timeout(state)}
  end

  @impl GenServer
  def handle_info(
        {:reply, task_id, _agent_id, {:result, result}},
        %State{task_id: task_id} = state
      ) do
    emit_completion(state, result)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(
        {:reply, task_id, _agent_id, {:failed, reason}},
        %State{task_id: task_id} = state
      ) do
    context = to_context(state)
    handle_failure(state, reason, context)
  end

  @impl GenServer
  def handle_info(:startup_timeout, %State{} = state) do
    emit_failure(state, :startup_timeout, true)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(:task_timeout, %State{} = state) do
    emit_failure(state, :task_timeout, true)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @spec to_context(State.t()) :: Context.t()
  defp to_context(%State{} = state) do
    %Context{
      agents: state.agents,
      workflow_id: state.workflow_id,
      task_id: state.task_id,
      task_spec: state.task_spec,
      attempt: state.attempt,
      cluster_id: state.cluster_id,
      space_id: state.space_id,
      reply_buffer: state.reply_buffer
    }
  end

  @spec maybe_spawn_timeouts(State.t()) :: State.t()
  defp maybe_spawn_timeouts(
         %State{task_spec: %Spec{startup_timeout_ms: startup_ms, timeout_ms: task_ms}} = state
       ) do
    startup_ref =
      case startup_ms do
        ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :startup_timeout, ms)
        nil -> nil
      end

    task_ref =
      case task_ms do
        ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :task_timeout, ms)
        nil -> nil
      end

    %State{state | startup_timeout_ref: startup_ref, task_timeout_ref: task_ref}
  end

  @spec cancel_startup_timeout(State.t()) :: State.t()
  defp cancel_startup_timeout(%State{startup_timeout_ref: nil} = state), do: state

  defp cancel_startup_timeout(%State{startup_timeout_ref: ref} = state)
       when is_reference(ref) do
    # Discard return value — timer may have already fired.
    _ = Process.cancel_timer(ref)
    %State{state | startup_timeout_ref: nil}
  end

  @spec handle_failure(State.t(), term(), map()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  defp handle_failure(%State{} = state, reason, context) do
    retriable? =
      Stc.Task.retriable?(state.task_spec.module, reason) and
        state.attempt < state.task_spec.retry_policy.max_attempts

    state.task_spec.module.clean(state.task_spec, context)

    if retriable? do
      emit_failure(state, reason, true)
      backoff_ms = state.task_spec.retry_policy.backoff_ms
      Process.send_after(self(), :start, backoff_ms)
      {:noreply, %State{state | attempt: state.attempt + 1}}
    else
      emit_failure(state, reason, false)
      {:stop, :normal, state}
    end
  end

  @spec emit_started(State.t(), term()) :: :ok
  defp emit_started(%State{} = state, handle) do
    {:ok, _cursor} =
      Store.append(%Event.Started{
        workflow_id: state.workflow_id,
        task_id: state.task_id,
        agent_ids: state.agent_ids,
        async_handle: handle,
        timestamp: DateTime.utc_now()
      })

    :ok
  end

  @spec emit_completion(State.t(), term()) :: :ok
  defp emit_completion(%State{} = state, result) do
    {:ok, _cursor} =
      Store.append(%Event.Completed{
        workflow_id: state.workflow_id,
        task_id: state.task_id,
        agent_ids: state.agent_ids,
        result: result,
        attempt: state.attempt,
        timestamp: DateTime.utc_now()
      })

    :ok
  end

  @spec emit_failure(State.t(), term(), boolean()) :: :ok
  defp emit_failure(%State{} = state, reason, retriable) do
    {:ok, _cursor} =
      Store.append(%Event.Failed{
        workflow_id: state.workflow_id,
        task_id: state.task_id,
        agent_ids: state.agent_ids,
        reason: reason,
        retriable: retriable,
        attempt: state.attempt,
        timestamp: DateTime.utc_now()
      })

    :ok
  end
end
