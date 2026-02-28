defmodule Stc.Interpreter.Distributed.State do
  @moduledoc false

  @type t :: %__MODULE__{
          cursor: Stc.Backend.EventLog.cursor()
        }

  defstruct [:cursor]
end

defmodule Stc.Interpreter.Distributed do
  @moduledoc """
  A GenServer that walks free-monad continuations as tasks complete.

  ## Event consumption

  Rather than subscribing to the event store (which would couple this module to
  backend push semantics), the walker maintains its own `cursor` and polls for
  `Completed` events each tick. This makes it backend-agnostic and deterministic.

  ## Tick interval

  `@poll_interval_ms` controls how frequently the walker checks for new completions.
  It is intentionally short relative to the scheduler's 1-second loop — the walker
  should emit `Ready` events for subsequent tasks before the next scheduler tick.
  """

  use GenServer
  alias Stc.Interpreter.Distributed.State

  require Logger

  alias Stc.Event.Store
  alias Stc.Program.Store, as: ProgramStore
  alias Stc.Op

  @poll_interval_ms 250

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %State{}, name: __MODULE__)
  end

  @impl true
  def init(%State{}) do
    state = %State{cursor: Store.origin()}
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %State{cursor: cursor} = state) do
    {:ok, events, new_cursor} =
      Store.fetch(cursor, types: [Stc.Event.Completed], limit: 100)

    Enum.each(events, &handle_completed/1)

    schedule_poll()
    {:noreply, %State{state | cursor: new_cursor}}
  end

  @impl true
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @spec handle_completed(Stc.Event.Completed.t()) :: :ok
  defp handle_completed(%Stc.Event.Completed{
         workflow_id: wf_id,
         task_id: task_id,
         result: result
       }) do
    case ProgramStore.get(wf_id) do
      {:ok, program} ->
        {next_program, ready_tasks} = next(program, task_id, result, wf_id)
        ProgramStore.put(wf_id, next_program)
        Enum.each(ready_tasks, &emit_ready(&1, wf_id))

      {:error, :not_found} ->
        Logger.warning(
          "Distributed walker: no program found for workflow_id=#{wf_id}, task_id=#{task_id}"
        )
    end
  end

  @spec emit_ready(map(), String.t()) :: :ok
  defp emit_ready(%{task_id: task_id, module: module, payload: payload}, wf_id) do
    event = %Stc.Event.Ready{
      workflow_id: wf_id,
      task_id: task_id,
      module: module,
      payload: payload,
      timestamp: DateTime.utc_now()
    }

    {:ok, _cursor} = Store.append(event)
    :ok
  end

  @spec next(term(), String.t(), term(), String.t()) :: {term(), [map()]}

  defp next(
         {:free, %Op.Unfold{step_fn: step_fn, current_step: current_step}, cont_fn},
         task_id,
         result,
         workflow_id
       ) do
    {updated_step, ready} = next(current_step, task_id, result, workflow_id)

    case updated_step do
      {:pure, step_result} ->
        case step_fn.(step_result) do
          {:cont, next_step} ->
            new_node = {:free, %Op.Unfold{step_fn: step_fn, current_step: next_step}, cont_fn}
            new_ready = extract_ready_tasks(next_step, workflow_id)
            {new_node, ready ++ new_ready}

          :halt ->
            next_program = cont_fn.(step_result)
            {next_program, ready ++ extract_ready_tasks(next_program, workflow_id)}
        end

      still_running ->
        {{:free, %Op.Unfold{step_fn: step_fn, current_step: still_running}, cont_fn}, ready}
    end
  end

  defp next({:pure, _} = program, _task_id, _result, _workflow_id) do
    {program, []}
  end

  defp next(
         {:free, %Op.Run{task_id: id}, cont_fn},
         task_id,
         result,
         workflow_id
       )
       when id == task_id do
    next_program = cont_fn.(result)
    ready_tasks = extract_ready_tasks(next_program, workflow_id)
    {next_program, ready_tasks}
  end

  defp next(
         {:free, %Op.Run{}, _cont_fn} = program,
         _task_id,
         _result,
         _workflow_id
       ) do
    {program, []}
  end

  defp next(
         {:free, %Op.Parallel{programs: programs}, cont_fn},
         task_id,
         result,
         workflow_id
       ) do
    {updated_programs, all_ready} =
      Enum.map_reduce(programs, [], fn prog, acc ->
        {updated, ready} = next(prog, task_id, result, workflow_id)
        {updated, acc ++ ready}
      end)

    if Enum.all?(updated_programs, &match?({:pure, _}, &1)) do
      results = Enum.map(updated_programs, fn {:pure, v} -> v end)
      next_program = cont_fn.(results)
      ready_from_cont = extract_ready_tasks(next_program, workflow_id)
      {next_program, all_ready ++ ready_from_cont}
    else
      {{:free, %Op.Parallel{programs: updated_programs}, cont_fn}, all_ready}
    end
  end

  defp next(
         {:free, %Op.Sequence{programs: []}, cont_fn},
         _task_id,
         _result,
         workflow_id
       ) do
    next_program = cont_fn.([])
    {next_program, extract_ready_tasks(next_program, workflow_id)}
  end

  defp next(
         {:free, %Op.Sequence{programs: [first | rest]}, cont_fn},
         task_id,
         result,
         workflow_id
       ) do
    {updated_first, ready_tasks} = next(first, task_id, result, workflow_id)

    case {updated_first, rest} do
      {{:pure, _}, []} ->
        next_program = cont_fn.([])
        ready_from_cont = extract_ready_tasks(next_program, workflow_id)
        {next_program, ready_tasks ++ ready_from_cont}

      {{:pure, _}, [next_prog | _]} ->
        updated_seq = {:free, %Op.Sequence{programs: rest}, cont_fn}
        ready_from_next = extract_ready_tasks(next_prog, workflow_id)
        {updated_seq, ready_tasks ++ ready_from_next}

      {still_running, _} ->
        {{:free, %Op.Sequence{programs: [still_running | rest]}, cont_fn}, ready_tasks}
    end
  end

  @spec extract_ready_tasks(term(), String.t()) :: [map()]

  defp extract_ready_tasks(
         {:free, %Op.Unfold{current_step: current_step}, _cont_fn},
         workflow_id
       ) do
    extract_ready_tasks(current_step, workflow_id)
  end

  defp extract_ready_tasks({:pure, _}, _workflow_id), do: []

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: nil, module: mod, payload: p}, _cont_fn},
         _workflow_id
       ) do
    [%{task_id: Ecto.UUID.generate(), module: mod, payload: p}]
  end

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, _cont_fn},
         _workflow_id
       ) do
    [%{task_id: id, module: mod, payload: p}]
  end

  defp extract_ready_tasks(
         {:free, %Op.Parallel{programs: programs}, _cont_fn},
         workflow_id
       ) do
    Enum.flat_map(programs, &extract_ready_tasks(&1, workflow_id))
  end

  defp extract_ready_tasks(
         {:free, %Op.Sequence{programs: []}, _cont_fn},
         _workflow_id
       ) do
    []
  end

  defp extract_ready_tasks(
         {:free, %Op.Sequence{programs: [first | _rest]}, _cont_fn},
         workflow_id
       ) do
    extract_ready_tasks(first, workflow_id)
  end

  defp extract_ready_tasks({:free, _other_op, _cont_fn}, _workflow_id), do: []

  @spec schedule_poll() :: reference()
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
