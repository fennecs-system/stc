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

  alias Stc.Event
  alias Stc.Event.Store
  alias Stc.ReplyBuffer
  alias Stc.Scheduler.Executor.State
  alias Stc.Task
  alias Stc.Task.Context
  alias Stc.Task.LivenessCheck

  alias Stc.Task.Policy
  alias Stc.Task.Policy.Retry
  alias Stc.Task.Result
  alias Stc.Task.Spec
  alias Stc.Task.Store, as: TaskStore

  require Logger

  # api

  @doc false
  def via(task_id) do
    {:via, Horde.Registry, {Stc.ExecutorRegistry, "executor_#{task_id}"}}
  end

  @doc false
  def start_link(config) do
    GenServer.start_link(__MODULE__, struct!(State, config), name: via(config.task_id))
  end

  @impl true
  def init(%State{} = state) do
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %State{} = state) do
    context = to_context(state)

    case find_stale_handle(state.task_id, state.workflow_id) do
      {:ok, handle} -> spawn_resume(state, handle, context)
      :not_found -> spawn_start(state, context)
    end
  end

  # Resume a task that was started/running before a crash.
  @spec spawn_resume(State.t(), term(), Context.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  defp spawn_resume(%State{} = state, handle, context) do
    with true <- Task.resumable?(state.task_spec.module),
         {:ok, task_result} <- state.task_spec.module.resume(state.task_spec, handle, context) do
      emit_completion(state, task_result)
      {:stop, :normal, state}
    else
      false ->
        # No resume: clean up previous attempt then start fresh.
        Task.clean(state.task_spec.module, state.task_spec, context)
        spawn_start(state, context)

      {:started, new_handle} ->
        state = %State{state | async_handle: new_handle}
        state = maybe_spawn_timeouts(state)
        state = spawn_liveness_checks(state)
        ReplyBuffer.register_executor(state.reply_buffer, state.task_id, self())
        emit_started(state, new_handle)
        {:noreply, state}

      {:error, reason} ->
        handle_failure(state, reason, context)
    end
  rescue
    err ->
      Logger.error(
        "Task #{state.task_id} raised in resume/3:\n#{Exception.format(:error, err, __STACKTRACE__)}"
      )

      handle_failure(state, {:exception, err}, context)
  catch
    kind, payload ->
      Logger.error(
        "Task #{state.task_id} threw in resume/3:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
      )

      handle_failure(state, {:thrown, {kind, payload}}, context)
  end

  @spec spawn_start(State.t(), Context.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  defp spawn_start(%State{} = state, context) do
    case state.task_spec.module.start(state.task_spec, context) do
      {:ok, task_result} ->
        emit_completion(state, task_result)
        {:stop, :normal, state}

      {:started, handle} ->
        state = %State{state | async_handle: handle}
        state = maybe_spawn_timeouts(state)
        state = spawn_liveness_checks(state)
        ReplyBuffer.register_executor(state.reply_buffer, state.task_id, self())
        emit_started(state, handle)
        {:noreply, state}

      {:error, reason} ->
        handle_failure(state, reason, context)
    end
  rescue
    err ->
      Logger.error(
        "Task #{state.task_id} raised in start/2:\n#{Exception.format(:error, err, __STACKTRACE__)}"
      )

      handle_failure(state, {:exception, err}, context)
  catch
    kind, payload ->
      Logger.error(
        "Task #{state.task_id} threw in start/2:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
      )

      handle_failure(state, {:thrown, {kind, payload}}, context)
  end

  @spec spawn_liveness_checks(State.t()) :: State.t()
  defp spawn_liveness_checks(%State{task_spec: %Spec{liveness_check: nil}} = state), do: state

  defp spawn_liveness_checks(%State{task_spec: %Spec{module: module}} = state) do
    if function_exported?(module, :running?, 3) do
      Process.send_after(self(), :liveness_check, state.task_spec.liveness_check.interval_ms)
    end

    state
  end

  # Returns {:ok, handle} when this task has a Started event with no matching
  # Completed — i.e. it was starting or running when the previous executor died.
  @spec find_stale_handle(String.t(), String.t()) :: {:ok, term()} | :not_found
  defp find_stale_handle(task_id, workflow_id) do
    opts = [task_id: task_id, workflow_id: workflow_id]

    # Check for completion first (limit: 1 — we only need to know if any exists).
    with {:ok, [], _} <-
           Store.fetch(Store.origin(), [{:types, [Stc.Event.Completed]}, {:limit, 1} | opts]),
         {:ok, started, _} <- Store.fetch(Store.origin(), [{:types, [Stc.Event.Started]} | opts]),
         %Stc.Event.Started{async_handle: handle} <- List.last(started) do
      {:ok, handle}
    else
      {:ok, [_ | _], _} -> :not_found
      nil -> :not_found
    end
  end

  @impl true
  def handle_info({:started_tick, task_id}, %State{task_id: task_id} = state) do
    {:noreply, cancel_startup_timeout(state)}
  end

  @impl true
  def handle_info({:reply, task_id, _agent_id, :started_tick}, %State{task_id: task_id} = state) do
    {:noreply, cancel_startup_timeout(state)}
  end

  @impl true
  def handle_info(
        {:reply, task_id, _agent_id, {:result, result}},
        %State{task_id: task_id} = state
      ) do
    # Agents send raw values; wrap here since they don't construct Result structs.
    state = cancel_continue_checks(state)
    emit_completion(state, Result.to_result(result))
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(
        {:reply, task_id, _agent_id, {:failed, reason}},
        %State{task_id: task_id} = state
      ) do
    context = to_context(state)
    handle_failure(state, reason, context)
  end

  @impl true
  def handle_info(:startup_timeout, %State{} = state) do
    state = cancel_continue_checks(state)
    emit_failure(state, :startup_timeout, true)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:task_timeout, %State{} = state) do
    state = cancel_continue_checks(state)
    emit_failure(state, :task_timeout, true)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:continue_check, policy}, %State{} = state) do
    context = to_context(state)

    case policy.__struct__.continue(policy, context) do
      :ok ->
        interval = Policy.Continue.check_interval_ms(policy)
        Process.send_after(self(), {:continue_check, policy}, interval)
        {:noreply, state}

      {:cancel, reason} ->
        Logger.warning(
          "Task #{state.task_id} cancelled by #{inspect(policy.__struct__)}: #{inspect(reason)}"
        )

        state = cancel_continue_checks(state)
        Task.clean(state.task_spec.module, state.task_spec, context)
        emit_failure(state, {:cancelled, reason}, false)
        {:stop, :normal, state}
    end
  rescue
    err ->
      Logger.error(
        "Task #{state.task_id} raised in continue check:\n#{Exception.format(:error, err, __STACKTRACE__)}"
      )

      state = cancel_continue_checks(state)
      emit_failure(state, {:exception, err}, false)
      {:stop, :normal, state}
  catch
    kind, payload ->
      Logger.error(
        "Task #{state.task_id} threw in continue check:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
      )

      state = cancel_continue_checks(state)
      emit_failure(state, {:thrown, {kind, payload}}, false)
      {:stop, :normal, state}
  end

  @impl true
  def handle_info(:liveness_check, %State{} = state) do
    context = to_context(state)

    %Spec{
      liveness_check: %LivenessCheck{interval_ms: interval, max_failures: max, window_ms: window}
    } = state.task_spec

    now = System.monotonic_time(:millisecond)

    state =
      case Task.running?(state.task_spec.module, state.task_spec, state.async_handle, context) do
        :ok ->
          # Clear any stale failures on a successful probe.
          %State{state | liveness_check_failures: []}

        {:not_running, reason} ->
          Logger.warning("Task #{state.task_id} liveness check failed: #{inspect(reason)}")
          recent = Enum.filter(state.liveness_check_failures, &(now - &1 < window))
          %State{state | liveness_check_failures: [now | recent]}
      end

    if length(state.liveness_check_failures) >= max do
      state = cancel_continue_checks(state)
      Task.clean(state.task_spec.module, state.task_spec, context)
      emit_failure(state, :liveness_check_failed, true)
      {:stop, :normal, state}
    else
      Process.send_after(self(), :liveness_check, interval)
      {:noreply, state}
    end
  rescue
    err ->
      Logger.error(
        "Task #{state.task_id} raised in liveness check:\n#{Exception.format(:error, err, __STACKTRACE__)}"
      )

      emit_failure(state, :liveness_check_failed, true)
      {:stop, :normal, state}
  catch
    kind, payload ->
      Logger.error(
        "Task #{state.task_id} threw in liveness check:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
      )

      emit_failure(state, :liveness_check_failed, true)
      {:stop, :normal, state}
  end

  @impl true
  def handle_info(:duration_elapsed, %State{} = state) do
    context = to_context(state)
    state = cancel_timers(state)

    try do
      Task.clean(state.task_spec.module, state.task_spec, context)
    rescue
      err ->
        Logger.error(
          "Task #{state.task_id} raised in clean/2 during duration_elapsed:\n#{Exception.format(:error, err, __STACKTRACE__)}"
        )
    catch
      kind, payload ->
        Logger.error(
          "Task #{state.task_id} threw in clean/2 during duration_elapsed:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
        )
    end

    emit_failure(state, :duration_elapsed, false)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:cancel, %State{} = state), do: do_cancel(state, :cancelled)

  @impl true
  def handle_info({:cancel, reason}, %State{} = state), do: do_cancel(state, reason)

  @impl true
  def handle_info({:preempt, reason}, %State{} = state) do
    state = cancel_timers(state)
    context = to_context(state)

    try do
      Task.clean(state.task_spec.module, state.task_spec, context)
    rescue
      err ->
        Logger.error(
          "Task #{state.task_id} raised in clean/2 during preemption:\n#{Exception.format(:error, err, __STACKTRACE__)}"
        )
    catch
      kind, payload ->
        Logger.error(
          "Task #{state.task_id} threw in clean/2 during preemption:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
        )
    end

    emit_preempted(state, reason)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{reply_buffer: rb, task_id: task_id}) do
    ReplyBuffer.unregister_executor(rb, task_id)
  end

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
  defp maybe_spawn_timeouts(%State{task_spec: spec} = state) do
    startup_ref = schedule_optional_timer(:startup_timeout, spec.startup_timeout_ms)
    task_ref = schedule_optional_timer(:task_timeout, spec.timeout_ms)
    duration_ref = schedule_optional_timer(:duration_elapsed, spec.duration_ms)
    continue_refs = schedule_continue_checks(spec)

    %State{
      state
      | startup_timeout_ref: startup_ref,
        task_timeout_ref: task_ref,
        duration_timeout_ref: duration_ref,
        continue_check_refs: continue_refs
    }
  end

  @spec schedule_optional_timer(term(), pos_integer() | nil) :: reference() | nil
  defp schedule_optional_timer(msg, ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), msg, ms)
  end

  defp schedule_optional_timer(_msg, _), do: nil

  @spec schedule_continue_checks(Spec.t()) :: [reference()]
  defp schedule_continue_checks(%Spec{policies: %{continue: [_ | _] = policies}}) do
    Enum.map(policies, fn policy ->
      interval = Policy.Continue.check_interval_ms(policy)
      Process.send_after(self(), {:continue_check, policy}, interval)
    end)
  end

  defp schedule_continue_checks(_), do: []

  @spec cancel_startup_timeout(State.t()) :: State.t()
  defp cancel_startup_timeout(%State{startup_timeout_ref: nil} = state), do: state

  defp cancel_startup_timeout(%State{startup_timeout_ref: ref} = state)
       when is_reference(ref) do
    # Discard return value — timer may have already fired.
    _ = Process.cancel_timer(ref)
    %State{state | startup_timeout_ref: nil}
  end

  @spec cancel_continue_checks(State.t()) :: State.t()
  defp cancel_continue_checks(%State{continue_check_refs: []} = state), do: state

  defp cancel_continue_checks(%State{continue_check_refs: refs} = state) do
    Enum.each(refs, &Process.cancel_timer/1)
    %State{state | continue_check_refs: []}
  end

  @spec cancel_timers(State.t()) :: State.t()
  defp cancel_timers(%State{} = state) do
    _ = if state.startup_timeout_ref, do: Process.cancel_timer(state.startup_timeout_ref)
    _ = if state.task_timeout_ref, do: Process.cancel_timer(state.task_timeout_ref)
    _ = if state.duration_timeout_ref, do: Process.cancel_timer(state.duration_timeout_ref)
    Enum.each(state.continue_check_refs, &Process.cancel_timer/1)

    %State{
      state
      | startup_timeout_ref: nil,
        task_timeout_ref: nil,
        duration_timeout_ref: nil,
        continue_check_refs: []
    }
  end

  @spec handle_failure(State.t(), term(), map()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  defp handle_failure(%State{} = state, reason, context) do
    retriable? =
      Stc.Task.retriable?(state.task_spec.module, reason) and
        state.attempt < state.task_spec.policies.retry.max_attempts

    try do
      state.task_spec.module.clean(state.task_spec, context)
    rescue
      err ->
        Logger.error(
          "Task #{state.task_id} raised in clean/2:\n#{Exception.format(:error, err, __STACKTRACE__)}"
        )
    catch
      kind, payload ->
        Logger.error(
          "Task #{state.task_id} threw in clean/2:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
        )
    end

    if retriable? do
      emit_failure(state, reason, true)
      backoff_ms = Retry.backoff_ms(state.task_spec.policies.retry, state.attempt)
      Process.send_after(self(), :start, backoff_ms)
      {:noreply, %State{state | attempt: state.attempt + 1}}
    else
      state = cancel_continue_checks(state)
      emit_failure(state, reason, false)
      {:stop, :normal, state}
    end
  end

  @spec do_cancel(State.t(), term()) :: {:stop, :normal, State.t()}
  defp do_cancel(%State{} = state, reason) do
    state = cancel_continue_checks(state)
    context = to_context(state)

    try do
      Task.clean(state.task_spec.module, state.task_spec, context)
    rescue
      err ->
        Logger.error(
          "Task #{state.task_id} raised in clean/2:\n#{Exception.format(:error, err, __STACKTRACE__)}"
        )
    catch
      kind, payload ->
        Logger.error(
          "Task #{state.task_id} threw in clean/2:\n#{Exception.format(kind, payload, __STACKTRACE__)}"
        )
    end

    emit_failure(state, reason, false)
    {:stop, :normal, state}
  end

  @spec emit_preempted(State.t(), term()) :: :ok
  defp emit_preempted(%State{} = state, reason) do
    {:ok, _cursor} =
      Store.append(%Event.Preempted{
        workflow_id: state.workflow_id,
        task_id: state.task_id,
        agent_ids: state.agent_ids,
        reason: reason,
        timestamp: DateTime.utc_now()
      })

    :ok
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
  defp emit_completion(%State{content_hash: hash} = state, result) when is_binary(hash) do
    # Write to store before emitting Completed so the cache is warm when the
    # walker emits the next task's Ready event.
    TaskStore.put(hash, result)
    do_emit_completion(state, result)
  end

  defp emit_completion(%State{} = state, result) do
    do_emit_completion(state, result)
  end

  @spec do_emit_completion(State.t(), term()) :: :ok
  defp do_emit_completion(%State{} = state, result) do
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
