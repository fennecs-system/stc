defmodule STC.ReplyBuffer do
  @moduledoc """
  A buffer for replies from agents

  For async tasks -> agents can send replies back to the executor via the scheduler's reply buffer
  """
  def start_link(opts) do
    scheduler_id = Keyword.fetch!(opts, :scheduler_id)
    GenServer.start_link(__MODULE__, opts, name: via(scheduler_id))
  end

  def init(opts) do
    scheduler_id = Keyword.fetch!(opts, :scheduler_id)

    {:ok,
     %{
       scheduler_id: scheduler_id,

       # map of task_id => [%{agent_id, message, timestamp}]
       buffer: %{}
     }}
  end

  def add_message(scheduler_id, task_id, agent_id, message) when is_binary(scheduler_id) do
    GenServer.call(via(scheduler_id), {:add_message, task_id, agent_id, message})
  end

  # directly dumping to pid - for internal use
  def add_message_via_pid(pid, task_id, agent_id, message) when is_pid(pid) do
    GenServer.call(pid, {:add_message, task_id, agent_id, message})
  end

  def handle_call({:add_message, task_id, agent_id, message}, _from, state) do
    new_entry = %{
      task_id: task_id,
      agent_id: agent_id,
      message: message,
      timestamp: DateTime.utc_now()
    }

    {:reply, :ok,
     %{
       state
       | buffer:
           Map.update(state.buffer, task_id, [new_entry], fn existing ->
             [new_entry | existing]
           end)
     }}
  end

  def via(scheduler_id) do
    {:via, Horde.Registry, {STC.SchedulerRegistry, "scheduler_reply_buffer_#{scheduler_id}"}}
  end
end
