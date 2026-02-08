defmodule STC.Interpreter.Distributed do
  @moduledoc """
  A GenServer that walks continuations and executes them.
  """
  use GenServer
  require Logger
  alias STC.Event.Store
  alias STC.Program.Store, as: ProgramStore
  alias STC.Op

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_state) do
    pid = self()
    Store.subscribe(pid)
    {:ok, %{}}
  end

  def handle_info(
        event,
        state
      ) do
    {:noreply, handle_event(event, state)}
  end

  def handle_event(
        %STC.Event.Completed{
          workflow_id: wf_id,
          task_id: task_id,
          result: result
        } = _event,
        state
      ) do
    {:ok, program} = ProgramStore.get(wf_id) |> dbg()

    {next_program, ready_tasks} =
      next(program, task_id, result, wf_id)
      |> dbg()

    ProgramStore.put(wf_id, next_program)

    Enum.each(ready_tasks, fn task_info ->
      event = %STC.Event.Ready{
        workflow_id: wf_id,
        task_id: task_info.task_id,
        module: task_info.module,
        payload: task_info.payload,
        timestamp: DateTime.utc_now()
      }

      Store.append(event)
    end)

    state
  end

  def handle_event(_event, state), do: state

  defp next({:pure, a}, _task_id, _result, workflow_id) do
    Logger.info("Workflow #{workflow_id} complete")
    {{:pure, a}, []}
  end

  defp next(
         {:free, %Op.Run{task_id: id}, cont_fn},
         task_id,
         result,
         workflow_id
       )
       when id == task_id do
    next_program = cont_fn.(result)
    IO.inspect(next_program, label: "Next fn : Next program after continuation #{id}")
    ready_tasks = extract_ready_tasks(next_program, workflow_id)
    {next_program, ready_tasks}
  end

  defp next(
         {:free, %Op.Run{} = _op, _cont_fn} = program,
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
    {updated_programs, all_ready_tasks} =
      Enum.map_reduce(programs, [], fn prog, acc_ready ->
        {updated, ready} = next(prog, task_id, result, workflow_id)
        {updated, acc_ready ++ ready}
      end)

    all_pure? =
      Enum.all?(updated_programs, fn prog -> match?({:pure, _}, prog) end)
      |> dbg()

    if all_pure? do
      Logger.debug("All parallel branches are pure, proceeding to continuation")
      results = Enum.map(updated_programs, fn {:pure, v} -> v end)
      next_program = cont_fn.(results)
      ready_from_cont = extract_ready_tasks(next_program, workflow_id)
      {next_program, all_ready_tasks ++ ready_from_cont}
    else
      Logger.debug("Not all parallel branches complete, waiting")
      {{:free, %Op.Parallel{programs: updated_programs}, cont_fn}, all_ready_tasks}
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

    with {:pure, _first} <- updated_first,
         [] <- rest do
      next_program = cont_fn.([])
      ready_from_cont = extract_ready_tasks(next_program, workflow_id)
      {next_program, ready_tasks ++ ready_from_cont}
    else
      {_, _} ->
        updated_seq = {:free, %Op.Sequence{programs: [updated_first | rest]}, cont_fn}
        {updated_seq, ready_tasks}

      [_ | _] ->
        updated_seq = {:free, %Op.Sequence{programs: rest}, cont_fn}
        ready_from_next = extract_ready_tasks(hd(rest), workflow_id)
        {updated_seq, ready_tasks ++ ready_from_next}
    end

    # case updated_first do
    #   {:pure, _first_result} ->
    #     if rest == [] do
    #       next_program = cont_fn.([])
    #       ready_from_cont = extract_ready_tasks(next_program, workflow_id)
    #       {next_program, ready_tasks ++ ready_from_cont}
    #     else
    #       updated_seq = {:free, %Op.Sequence{programs: rest}, cont_fn}
    #       ready_from_next = extract_ready_tasks(hd(rest), workflow_id)
    #       {updated_seq, ready_tasks ++ ready_from_next}
    #     end

    #   _ ->
    #     updated_seq = {:free, %Op.Sequence{programs: [updated_first | rest]}, cont_fn}
    #     {updated_seq, ready_tasks}
    # end
  end

  defp extract_ready_tasks({:pure, _}, _workflow_id), do: []

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: nil, module: mod, payload: p}, _cont_fn},
         _workflow_id
       ) do
    id = Ecto.UUID.generate() |> dbg()
    [%{task_id: id, module: mod, payload: p}]
  end

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, _cont_fn},
         _workflow_id
       ) do
    [%{task_id: id, module: mod, payload: p}]
  end

  defp extract_ready_tasks(
         {:free, %Op.Parallel{programs: programs}, _},
         workflow_id
       ),
       do: Enum.flat_map(programs, &extract_ready_tasks(&1, workflow_id))

  defp extract_ready_tasks(
         {:free, %Op.Sequence{programs: []}, _},
         _workflow_id
       ),
       do: []

  defp extract_ready_tasks(
         {:free, %Op.Sequence{programs: [first | _rest]}, _},
         workflow_id
       ),
       do: extract_ready_tasks(first, workflow_id)

  # other ops
  defp extract_ready_tasks(
         {:free, _, _},
         _workflow_id
       ),
       do: []
end
