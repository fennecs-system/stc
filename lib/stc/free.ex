defmodule STC.Free do
  @moduledoc """
  A free monad
  """

  @doc false
  def pure(value), do: {:pure, value}

  @doc false
  def bind({:pure, value}, op), do: op.(value)
  def bind({:free, op, next}, f), do: {:free, op, fn x -> bind(next.(x), f) end}

  @doc false
  def fmap(free, f), do: bind(free, fn x -> pure(f.(x)) end)

  @doc false
  def zip_with(free_a, free_b, f) do
    bind(free_a, fn a ->
      bind(free_b, fn b ->
        pure(f.(a, b))
      end)
    end)
  end

  @doc """
  Iterate a program n times, passing results forward
  """
  def iterate(init, n, f) do
    Enum.reduce(1..n, pure(init), fn i, acc ->
      bind(acc, fn state -> f.(state, i) end)
    end)
  end

  @doc """
  Replicate a program n times in sequence, discarding results
  """
  def replicate(program, n) do
    iterate(nil, n, fn _state, _i ->
      bind(program, fn _ -> pure(nil) end)
    end)
  end

  @doc """
  Cycle a program infinitely
  """
  def cycle(init, f) do
    bind(f.(init), fn next ->
      cycle(next, f)
    end)
  end
end
