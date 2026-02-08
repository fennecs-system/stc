defmodule STC.Scheduler.Algorithm.LocalTestAlgorithm do
  @moduledoc """
  A simple local test scheduling algorithm. All it does is spawn local agents (just a simple Task).
  """
  alias STC.Agent.LocalTestAgent

  @behaviour STC.Scheduler.Algorithm

  def refresh_agent_pool(state) do
    # For local test algorithm, just return some dummy agents" end)
    agents =
      Enum.map(1..5, fn i -> %LocalTestAgent{id: "local_test_agent_#{i}", status: :active} end)

    %{state | agent_pool: agents}
  end

  # overide for how to handle stale agents
  def reconcile_stale_agents(state) do
    # For local test algorithm, we can just return the state as is
    state
  end

  def schedule_event_order(events, _state) do
    # no special ordering for local test algorithm
    events
  end

  # how to select an agent for a task
  def select_agents_for_event(_event, [agent | _available], _state) do
    {:ok, [agent]}
  end

  def select_agents_for_event(_event, [], _state) do
    {:error, :no_agents_available}
  end

  def process_agent_buffer(state), do: state
end
