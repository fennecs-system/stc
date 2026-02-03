defmodule STC.ReplyBuffer do
  @moduledoc """
  A buffer for replies from agents
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
       buffer: []
     }}
  end

  def add_message(scheduler_id, task_id, agent_id, message) do
    GenServer.call(via(scheduler_id), {:add_message, task_id, agent_id, message})
  end

  def handle_call({:add_message, task_id, agent_id, message}, _from, state) do
    new_entry = %{
      task_id: task_id,
      agent_id: agent_id,
      message: message,
      timestamp: DateTime.utc_now()
    }

    {:reply, :ok, %{state | buffer: [state.buffer | new_entry]}}
  end

  def via(scheduler_id) do
    {:via, Horde.Registry, {STC.SchedulerRegistry, "scheduler_reply_buffer_#{scheduler_id}"}}
  end
end
