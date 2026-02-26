defmodule Stc.Scheduler.Algorithm.LocalTestAlgorithm do
  @moduledoc """
  A simple local test scheduling algorithm.

  Populates the agent pool with a fixed set of in-process `LocalTestAgent` instances
  and selects the first available agent for every task. Suitable for single-node
  integration tests; not intended for production use.
  """

  use Stc.Scheduler.Algorithm

  alias Stc.Agent.LocalTestAgent

  @impl Stc.Scheduler.Algorithm
  def refresh_agent_pool(state) do
    agents =
      Enum.map(1..5, fn i ->
        %LocalTestAgent{id: "local_test_agent_#{i}", status: :active}
      end)

    %{state | agent_pool: agents}
  end

  @impl Stc.Scheduler.Algorithm
  def select_agents_for_event(_event, [agent | _rest], _state) do
    {:ok, [agent]}
  end

  def select_agents_for_event(_event, [], _state) do
    {:error, :no_agents_available}
  end

  @impl Stc.Scheduler.Algorithm
  def schedule_event_order(events, _state), do: events

  @impl Stc.Scheduler.Algorithm
  def process_agent_buffer(state), do: state
end
