defmodule Stc.Free do
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

  @doc """
  Unfold a program from a seed, running one step at a time.

  `step_fn` is called with the seed (and subsequently with each step's result).
  It must return either `{:cont, program}` to run `program` and continue, or `:halt`
  to stop. The final result propagated outward is the last step's return value.

  Each step is only emitted after the previous one completes. Useful for example - giving
  natural single-file backpressure for paginated sources.

  ## Example

      # Count up from 0, halting when the result reaches 3.
      unfold(0, fn
        n when n < 3 -> {:cont, Program.run(IncrTask, %{n: n})}
        _            -> :halt
      end)
  """
  @spec unfold(seed :: term(), step_fn :: Stc.Op.Unfold.step_fn()) :: term()
  def unfold(seed, step_fn) do
    case step_fn.(seed) do
      {:cont, program} ->
        {:free, %Stc.Op.Unfold{step_fn: step_fn, current_step: program}, &pure/1}

      :halt ->
        pure(seed)
    end
  end
end
