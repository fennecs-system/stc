defmodule Stc.ReplyBuffer.State do
  @moduledoc false
  defstruct scheduler_id: nil, buffer: %{}, executors: %{}

  @type entry :: %{
          task_id: String.t(),
          agent_id: String.t(),
          message: term(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          scheduler_id: String.t(),
          buffer: %{String.t() => [entry()]},
          executors: %{String.t() => pid()}
        }
end

defmodule Stc.ReplyBuffer do
  @moduledoc """
  Per-scheduler buffer for messages arriving from agents.

  ## Async task signalling

  For async tasks, agents communicate back to the executor via this buffer. Two
  message shapes are supported:

    - `:started_tick` — the agent has acknowledged it started work. The executor uses
      this to cancel its startup timeout.
    - `{:result, result}` — the agent has finished; the executor emits `Completed`.
    - `{:failed, reason}` — the agent has failed; the executor handles retry/failure.

  ## Executor forwarding

  When an executor begins an async task it calls `register_executor/3` to associate
  its PID with a `task_id`. Subsequent `add_message/4` calls for that `task_id` are
  forwarded directly to the executor via `send/2`, in addition to being buffered. This
  decouples the agent (which calls `add_message` without knowing the executor's PID)
  from the executor (which receives messages without knowing how the agent reached it).

  The executor is referenced only by PID — no registry lookups required.
  """

  use GenServer
  alias Stc.ReplyBuffer.State

  @doc false
  def start_link(opts) do
    scheduler_id = Keyword.fetch!(opts, :scheduler_id)
    GenServer.start_link(__MODULE__, opts, name: via(scheduler_id))
  end

  @doc """
  Registers `executor_pid` as the receiver of forwarded messages for `task_id`.

  Called by `Stc.Scheduler.Executor` immediately after the task module returns
  `{:started, handle}`. Must be called before any agent calls `add_message/4` for
  this task to guarantee delivery; in practice the agent cannot respond before the
  executor has registered.
  """
  @spec register_executor(pid(), String.t(), pid()) :: :ok
  def register_executor(reply_buffer_pid, task_id, executor_pid)
      when is_pid(reply_buffer_pid) and is_binary(task_id) and is_pid(executor_pid) do
    GenServer.call(reply_buffer_pid, {:register_executor, task_id, executor_pid})
  end

  @doc """
  Adds a message from `agent_id` for `task_id`.

  The message is buffered and, if an executor has registered for this `task_id`,
  forwarded to it immediately via `send/2`. The forwarded message shape is:

      {:reply, task_id, agent_id, message}
  """
  @spec add_message(String.t(), String.t(), String.t(), term()) :: :ok
  def add_message(scheduler_id, task_id, agent_id, message)
      when is_binary(scheduler_id) and is_binary(task_id) do
    GenServer.call(via(scheduler_id), {:add_message, task_id, agent_id, message})
  end

  @doc "Variant that accepts a PID instead of a scheduler_id string."
  @spec add_message_via_pid(pid(), String.t(), String.t(), term()) :: :ok
  def add_message_via_pid(pid, task_id, agent_id, message)
      when is_pid(pid) and is_binary(task_id) do
    GenServer.call(pid, {:add_message, task_id, agent_id, message})
  end

  @doc false
  def via(scheduler_id) do
    {:via, Horde.Registry, {Stc.SchedulerRegistry, "scheduler_reply_buffer_#{scheduler_id}"}}
  end

  @impl true
  def init(opts) do
    scheduler_id = Keyword.fetch!(opts, :scheduler_id)
    {:ok, %State{scheduler_id: scheduler_id}}
  end

  @impl true
  def handle_call(
        {:register_executor, task_id, executor_pid},
        _from,
        %State{executors: executors} = state
      ) do
    {:reply, :ok, %State{state | executors: Map.put(executors, task_id, executor_pid)}}
  end

  @impl true
  def handle_call(
        {:add_message, task_id, agent_id, message},
        _from,
        %State{executors: executors, buffer: buffer} = state
      ) do
    # Forward to executor if registered.
    case Map.get(executors, task_id) do
      nil -> :ok
      pid -> send(pid, {:reply, task_id, agent_id, message})
    end

    entry = %{
      task_id: task_id,
      agent_id: agent_id,
      message: message,
      timestamp: DateTime.utc_now()
    }

    new_buffer = Map.update(buffer, task_id, [entry], &[entry | &1])

    {:reply, :ok, %State{state | buffer: new_buffer}}
  end
end
