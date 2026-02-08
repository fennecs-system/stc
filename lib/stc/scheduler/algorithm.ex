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

  @callback process_agent_buffer(state ::  struct()) :: struct()


  @optional_callbacks schedule_event_order: 2, process_agent_buffer:1

  # default behaviour, no special ordering.
  def schedule_event_order(module, events, state) do
    if function_exported?(module, :schedule_event_order?, 2) do
      module.schedule_event_order(events, state)
    else
      events
    end
  end

  def process_agent_buffer(module, state) do
    if function_exported?(module, :schedule_event_order?, 2) do
      module.process_agent_buffer(state)
    else
      events
    end
  end



end
