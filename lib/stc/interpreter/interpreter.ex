defmodule STC.Interpreter do
  @moduledoc """
  Interpreter for STC programs
  """

  alias STC.Event
  alias STC.Event.Store
  alias STC.Op
  alias STC.Spec
  alias STC.Program.Store, as: ProgramStore

  def local(program, context) do
    interpret_local(program, context)
  end

  defp interpret_local({:pure, a}, _context) do
    {:ok, a}
  end

  defp interpret_local(
         {:free, %Op.Run{task_id: id, module: mod, payload: payload}, cont_fn},
         context
       ) do
    exec_context = Map.put(context, :task_id, id)
    task_spec = Spec.new(mod, payload)

    Store.append(%Event.Started{
      task_id: id,
      workflow_id: Map.get(context, :workflow_id, nil),
      agent_ids: Map.get(context, :agent_ids, nil),
      async_handle: nil,
      timestamp: DateTime.utc_now()
    })

    case mod.execute(task_spec, exec_context) do
      {:ok, result} ->
        interpret_local(cont_fn.(result), context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp interpret_local(
         {:free, %Op.Sequence{programs: programs}, cont_fn},
         context
       ) do
    results =
      Enum.reduce_while(programs, {:ok, []}, fn prog, {:ok, acc} ->
        case interpret_local(prog, context) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, results} ->
        interpret_local(cont_fn.(Enum.reverse(results)), context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp interpret_local(
         {:free, %Op.Parallel{programs: programs}, cont_fn},
         context
       ) do
    results =
      programs
      |> Enum.map(fn p -> Task.async(fn -> interpret_local(p, context) end) end)
      |> Enum.map(&Task.await/1)

    case Enum.find(results, fn {status, _} -> status == :error end) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        ok_results = Enum.map(results, fn {:ok, r} -> r end)
        interpret_local(cont_fn.(ok_results), context)
    end
  end

  defp interpret_local(
         {:free, %Op.EmitEvent{}, cont_fn},
         context
       ) do
    # Skip events in local mode
    interpret_local(cont_fn.(:ok), context)
  end

  defp interpret_local(
         {:free, %Op.OnFailure{}, cont_fn},
         context
       ) do
    # Skip in local mode
    interpret_local(cont_fn.(:ok), context)
  end

  def distributed(program, context) do
    # store the program in the program store
    ProgramStore.put(context.workflow_id, program)

    interpret_distributed(program, context)
  end

  defp interpret_distributed({:pure, a}, _context) do
    {:ok, a}
  end

  defp interpret_distributed(
         {:free,
          %Op.Run{
            task_id: id,
            module: mod,
            payload: payload,
            space_affinity: affinity
          }, cont_fn},
         context
       ) do
    # Emit TaskReady event for schedulers to pick up
    event = %Event.Ready{
      workflow_id: context.workflow_id,
      task_id: id,
      module: mod,
      payload: payload,
      space_affinity: affinity,
      timestamp: DateTime.utc_now()
    }

    Store.append(event)

    # Continue with :scheduled (task is queued, not executed yet)
    {:ok, :scheduled}
  end

  defp interpret_distributed(
         {:free, %Op.Sequence{programs: [program | _]}, cont_fn},
         context
       ) do
    # emit a ready task for the first program in the sequence
    interpret_distributed(program, context)
  end

  defp interpret_distributed(
         {:free, %Op.Sequence{programs: []}, cont_fn},
         context
       ) do
    # nothing to do
    {:ok, :done}
  end

  defp interpret_distributed(
         {:free, %Op.Parallel{programs: programs}, cont_fn},
         context
       ) do
    # Emit all tasks at once
    Enum.each(programs, fn prog ->
      interpret_distributed(prog, context)
    end)
  end

  def trace(program) do
    collect_steps(program)
  end

  defp collect_steps({:pure, a}), do: {:pure, a}

  defp collect_steps({:free, %Op.Run{task_id: id, module: mod}, _cont_fn}) do
    {:run, id, mod}
  end

  defp collect_steps({:free, %Op.Parallel{programs: programs}, _cont_fn}) do
    {:parallel, Enum.map(programs, &collect_steps/1)}
  end

  defp collect_steps({:free, %Op.Sequence{programs: programs}, _cont_fn}) do
    {:sequence, Enum.map(programs, &collect_steps/1)}
  end

  defp collect_steps({:free, %Op.EmitEvent{event: event}, _cont_fn}) do
    {:emit_event, event}
  end

  defp collect_steps({:free, %Op.OnFailure{task_id: id, handler: _handler}, _cont_fn}) do
    {:on_failure, id}
  end

  defp collect_steps(_), do: :woof
end
