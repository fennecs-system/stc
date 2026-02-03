defmodule STC.Scheduler.Algorithm do
  @moduledoc """
  Behaviour for scheduling strategies
  """

  # how to refresh the agent pool
  @callback refresh_agent_pool(state :: struct()) :: struct()

  # overide for how to handle stale agents
  @callback reconcile_stale_agents(state :: struct()) :: struct()

  @callback select_agents_for_event(event :: map(), free_agents :: list(), state :: struct()) ::
              {:ok, agent_ids :: any()} | :no_agents_available

  @callback schedule_event_order(events :: list(), state :: struct()) :: list()
end
