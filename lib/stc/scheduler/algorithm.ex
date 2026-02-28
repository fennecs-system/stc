defmodule Stc.Scheduler.Algorithm do
  @moduledoc """
  Behaviour for pluggable scheduling strategies.

  Implement this behaviour to customise how the scheduler selects agents, orders
  events, and decides whether agents are eligible for a given task.

  ## Default implementations

  `use Stc.Scheduler.Algorithm` to get no-op or sensible default implementations
  for all optional callbacks. Override only what you need.

      defmodule MyAlgorithm do
        use Stc.Scheduler.Algorithm

        @impl Stc.Scheduler.Algorithm
        def select_agents_for_event(event, available, _state) do
          {:ok, Enum.take(available, event.task_spec.required_agents)}
        end
      end
  """

  alias Stc.Scheduler.State

  #
  # Required callbacks -
  #

  @doc "Refreshes the agent pool in state (e.g. from a registry or external API)."
  @callback refresh_agent_pool(state :: State.t()) :: State.t()

  @doc "Selects which agents from `free_agents` should run `event`."
  @callback select_agents_for_event(
              event :: Stc.Event.Ready.t(),
              free_agents :: [Stc.Agent.t()],
              state :: State.t()
            ) :: {:ok, [Stc.Agent.t()]} | {:error, :no_agents_available}

  @doc "Reorders the batch of fetched events before dispatch. Default: identity."
  @callback schedule_event_order(events :: [struct()], state :: State.t()) :: [struct()]

  @doc "Processes any buffered agent replies. Default: no-op."
  @callback process_agent_buffer(state :: State.t()) :: State.t()

  #
  # Optional callbacks
  #

  @doc """
  Returns `true` if `agent` satisfies the requirements of `event`.

  Called before agent capacity checks. Default: always `true`.
  """
  @callback agent_matches_requirements?(
              agent :: Stc.Agent.t(),
              event :: Stc.Event.Ready.t()
            ) :: boolean()

  @doc """
  Returns `true` if `agent` may accept `event` even when already at capacity.

  Default: always `false`.
  """
  @callback can_oversubscribe?(
              agent :: Stc.Agent.t(),
              event :: Stc.Event.Ready.t(),
              state :: State.t()
            ) :: boolean()

  @doc "Reconciles stale agents (e.g. timed-out or unresponsive). Default: no-op."
  @callback reconcile_stale_agents(state :: State.t()) :: State.t()

  @optional_callbacks [
    agent_matches_requirements?: 2,
    can_oversubscribe?: 3,
    reconcile_stale_agents: 1
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Stc.Scheduler.Algorithm

      @impl Stc.Scheduler.Algorithm
      def agent_matches_requirements?(_agent, _event), do: true

      @impl Stc.Scheduler.Algorithm
      def can_oversubscribe?(_agent, _event, _state), do: false

      @impl Stc.Scheduler.Algorithm
      def reconcile_stale_agents(state), do: state

      defoverridable agent_matches_requirements?: 2,
                     can_oversubscribe?: 3,
                     reconcile_stale_agents: 1
    end
  end
end
