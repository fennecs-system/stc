defmodule STC.Scheduler.Algorithm do
  @moduledoc """
  Behaviour for scheduling strategies
  """
  alias STC.Scheduler.State

  # how to refresh the agent pool
  @callback refresh_agent_pool(state :: State.t()) :: State.t()

  # overide for how to handle stale agents
  @callback reconcile_stale_agents(state :: State.t()) :: State.t()

  @callback select_agents_for_event(event :: map(), free_agents :: list(), state :: State.t()) ::
              {:ok, agent_ids :: any()} | :no_agents_available

  @callback schedule_event_order(events :: list(), state :: State.t()) :: list()

  @callback process_agent_buffer(state :: State.t()) :: State.t()
end
