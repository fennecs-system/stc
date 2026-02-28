defmodule Stc.Backend.Memory.KV.State do
  @moduledoc false

  @type t :: %__MODULE__{
          store: %{String.t() => binary()}
        }

  defstruct store: %{}
end

defmodule Stc.Backend.Memory.KV do
  @moduledoc """
  In-memory implementation of `Stc.Backend.KV`.

  Values are stored as raw binaries in a plain map. All operations are serialised
  through a single GenServer process, giving linearisable reads and writes.

  ## Usage

  Start once in your supervision tree (typically via `Stc.Backend.Supervisor`):

      children = [Stc.Backend.Memory.KV]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  @behaviour Stc.Backend.KV

  use GenServer
  alias Stc.Backend.Memory.KV.State
  # ---------------------------------------------------------------------------
  # Internal state
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %State{}, name: name)
  end

  @impl Stc.Backend.KV
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, value) when is_binary(key) and is_binary(value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @impl Stc.Backend.KV
  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @impl Stc.Backend.KV
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @impl Stc.Backend.KV
  @spec list_keys() :: {:ok, [String.t()]}
  def list_keys do
    GenServer.call(__MODULE__, :list_keys)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%State{} = state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, %State{store: store} = state) do
    {:reply, :ok, %State{state | store: Map.put(store, key, value)}}
  end

  @impl true
  def handle_call({:get, key}, _from, %State{store: store} = state) do
    case Map.fetch(store, key) do
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, %State{store: store} = state) do
    {:reply, :ok, %State{state | store: Map.delete(store, key)}}
  end

  @impl true
  def handle_call(:list_keys, _from, %State{store: store} = state) do
    {:reply, {:ok, Map.keys(store)}, state}
  end
end
