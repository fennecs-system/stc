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

  defp walk_program({:pure, a}, _completed), do: {:pure, a}

  defp walk_program({:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn}, completed)
       when is_map_key(completed, id) do
    result = Map.get(completed, id)
    walk_program(cont_fn.(result), completed)
  end

  defp walk_program({:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn}, _completed) do
    {:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn}
  end

  defp walk_program({:free, %Op.Parallel{programs: programs}, cont_fn}, completed) do
    walked_programs = Enum.map(programs, &walk_program(&1, completed))
    {:free, %Op.Parallel{programs: walked_programs}, cont_fn}
  end

  defp walk_program({:free, %Op.Sequence{programs: programs}, cont_fn}, completed) do
    walked_programs = Enum.map(programs, &walk_program(&1, completed))
    {:free, %Op.Sequence{programs: walked_programs}, cont_fn}
  end

  defp walk_program(list, completed) when is_list(list),
    do: Enum.map(list, &walk_program(&1, completed))

  def init(state) do
    # subscribe to events
    pid = self()
    Store.subscribe(pid)

    {:ok, %{completed_tasks: %{}}}
  end

  def handle_info(
        %STC.Event.Completed{
          workflow_id: wf_id,
          task_id: task_id,
          result: result
        } = event,
        state
      ) do
    state = handle_completed(event, state)
    {:noreply, state}
  end

  def handle_info(event, state) do
    # Logger.info("Received event: #{inspect(event)}")
    {:noreply, state}
  end

  def handle_completed(
        %STC.Event.Completed{
          workflow_id: wf_id,
          task_id: task_id,
          result: result
        } = event,
        state
      ) do
    completed = Map.get(state.completed_tasks, wf_id, %{})

    if Map.has_key?(completed, task_id) do
      Logger.debug("Task #{task_id} already processed")
      state
    else
      # Logger.info("Task #{task_id} completed for workflow #{wf_id}")

      completed = Map.get(state.completed_tasks, wf_id, %{})
      completed = Map.put(completed, task_id, result)

      # Logger.info("Completed tasks for workflow #{wf_id}: #{inspect(completed)}")

      state = put_in(state.completed_tasks[wf_id], completed)

      # Expand the program tree with the result of walking the continuations
      program = ProgramStore.get(wf_id) |> dbg(label: "Program before completing task #{task_id}")

      completed |> dbg(label: "Completed tasks before completing task #{task_id}")

      next_tasks =
        next(program, completed, wf_id)
        |> dbg(label: "Next tasks after completing task #{task_id}")

      # emit TaskReady for next tasks
      Enum.each(next_tasks, fn task_info ->
        event = %STC.Event.Ready{
          workflow_id: wf_id,
          task_id: task_info.task_id,
          module: task_info.module,
          payload: task_info.payload,
          timestamp: DateTime.utc_now()
        }

        Store.append(event)
      end)

      # update the program store with the new program state - the result of it being walked

      expanded_program =
        walk_program(program, completed)
        |> dbg(label: "Expanded program after completing task #{task_id}")

      ProgramStore.put(wf_id, expanded_program)

      state
    end
  end

  defp next({:pure, _a}, completed_tasks, workflow_id) do
    Logger.info("Worfklow #{workflow_id} complete")
    []
  end

  defp next(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn},
         completed_tasks,
         workflow_id
       )
       when is_map_key(completed_tasks, id) do
    result = Map.get(completed_tasks, id)
    next_program = cont_fn.(result)
    IO.inspect(next_program, label: "Next fn : Next program after continuation #{id}")
    IO.inspect(completed_tasks, label: "Completed tasks")
    extract_ready_tasks(next_program, workflow_id, completed_tasks)
  end

  # not ready
  defp next(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn},
         completed_tasks,
         workflow_id
       ),
       do: [%{task_id: id, module: mod, payload: p}]

  defp next({:free, %Op.Parallel{programs: programs}, cont_fn}, completed_tasks, workflow_id) do
    task_ids = collect_task_ids(programs) |> dbg()

    # issue! walking the program seems like it causes an issue with continuations being lost

    all_complete? =
      Enum.all?(task_ids, fn id -> Map.has_key?(completed_tasks, id) end)
      |> dbg(label: "All complete for parallel #{inspect(task_ids)}")

    all_pure? =
      Enum.all?(programs, fn prog -> match?({:pure, _}, prog) end)
      |> dbg(label: "All pure for parallel #{inspect(task_ids)}")

    # every result must be :pure before calling continuation
    cond do
      all_pure? ->
        Logger.debug("All parallel branches are pure, proceeding to continuation")
        results = Enum.map(task_ids, fn id -> Map.get(completed_tasks, id) end)
        next_program = cont_fn.(results)
        extract_ready_tasks(next_program, workflow_id, completed_tasks)

      not all_complete? ->
        # can maybe start on some of the tasks that arent pure
        Logger.debug("Not all parallel branches complete, waiting")
        []

      true ->
        # all complete but not all pure - call continuations on non pure branches
        task_ids = Enum.flat_map(programs, &collect_task_ids/1)

        next_results =
          Enum.map(task_ids, fn id -> Map.get(completed_tasks, id) end)
          |> dbg(label: "Results of parallel tasks #{inspect(task_ids)}")

        next_programs =
          Enum.map(programs, fn prog ->
            case prog do
              {:pure, _} ->
                prog

              {:free, _, cont_fn} ->
                result = Map.get(completed_tasks, prog |> collect_task_ids() |> hd())
                cont_fn.(result)
            end
          end)

        Enum.flat_map(next_programs, &extract_ready_tasks(&1, workflow_id, completed_tasks))
    end

    # if all_complete? and all_pure? do
    #   results =
    #     Enum.map(task_ids, fn id -> Map.get(completed_tasks, id) end)
    #     |> dbg(label: "Results of parallel tasks #{inspect(task_ids)}")

    #   next_program = cont_fn.(results) |> dbg(label: "Next program after parallel continuation")
    #   extract_ready_tasks(next_program, workflow_id, completed_tasks)
    # else
    #   []
    # end
  end

  defp next(
         {:free, %Op.Sequence{programs: []}, cont_fn},
         completed_tasks,
         workflow_id
       ) do
    next_program = cont_fn.([])
    extract_ready_tasks(next_program, workflow_id, completed_tasks)
  end

  defp next(
         {:free, %Op.Sequence{programs: programs}, cont_fn},
         completed_tasks,
         workflow_id
       ) do
    seq(programs, cont_fn, completed_tasks, workflow_id)
  end

  defp seq([], cont_fn, completed_tasks, workflow_id) do
    next_program = cont_fn.([])
    extract_ready_tasks(next_program, workflow_id, completed_tasks)
  end

  defp seq([first | rest], cont_fn, completed_tasks, workflow_id) do
    first_task_ids = collect_task_ids(first)

    all_first_complete? =
      Enum.all?(first_task_ids, fn id -> Map.has_key?(completed_tasks, id) end)

    if all_first_complete? do
      # First is done, check rest
      seq(rest, cont_fn, completed_tasks, workflow_id)
    else
      # First not done, wait
      []
    end
  end

  defp collect_task_ids({:pure, _}), do: []

  defp collect_task_ids({:free, %Op.Run{task_id: id}, _}), do: [id]

  defp collect_task_ids({:free, %Op.Parallel{programs: programs}, _}),
    do: Enum.flat_map(programs, &collect_task_ids/1)

  defp collect_task_ids({:free, %Op.Sequence{programs: programs}, _}),
    do: Enum.flat_map(programs, &collect_task_ids/1)

  defp collect_task_ids(list) when is_list(list), do: Enum.flat_map(list, &collect_task_ids/1)

  # other branches raise

  defp extract_ready_tasks({:pure, _}, _workflow_id, _completed_tasks), do: []

  # defp extract_ready_tasks(
  #        {:free, %Op.Run{task_id: id, module: mod, payload: p}, _},
  #        workflow_id,
  #        completed_tasks
  #      )
  #      when is_map_key(completed_tasks, id),
  #      # Don't emit if already completed
  #      do: []

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, cont_fn},
         workflow_id,
         completed_tasks
       )
       when is_map_key(completed_tasks, id) do
    cont_fn |> dbg(label: "cont_fn")
    result = Map.get(completed_tasks, id)
    IO.inspect(result, label: "Passing result to continuation for task #{id}")
    next_program = cont_fn.(result)
    IO.inspect(next_program, label: "Next program after continuation #{id}")
    next_payload = result

    extract_ready_tasks(next_program, workflow_id, completed_tasks)
  end

  defp extract_ready_tasks(
         {:free, %Op.Run{task_id: id, module: mod, payload: p}, _cont_fn},
         _workflow_id,
         completed_tasks
       ),
       # Task not completed yet, it's ready
       do: [%{task_id: id, module: mod, payload: p}]

  defp extract_ready_tasks(
         {:free, %Op.Parallel{programs: programs}, _},
         workflow_id,
         completed_tasks
       ),
       do: Enum.flat_map(programs, &extract_ready_tasks(&1, workflow_id, completed_tasks))

  defp extract_ready_tasks(
         {:free, %Op.Sequence{programs: [first | _]}, _},
         workflow_id,
         completed_tasks
       ),
       do: extract_ready_tasks(first, workflow_id, completed_tasks)
end
