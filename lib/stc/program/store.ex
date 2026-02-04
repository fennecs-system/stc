defmodule STC.Program.Store do
  @moduledoc """
  A table for storing a program to track progress in distributed execution.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    binary = :erlang.term_to_binary(value)
    new_state = Map.put(state, key, binary) |> dbg()
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) when is_map_key(state, key) do
    binary = Map.get(state, key)
    value = :erlang.binary_to_term(binary)
    {:reply, {:ok, value}, state}
  end

  def handle_call({:get, key}, _from, state) when is_map_key(state, key) do
    {:reply, {:error, nil}, state}
  end

end
