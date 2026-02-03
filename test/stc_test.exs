defmodule StcTest do
  use ExUnit.Case
  doctest Stc

  test "greets the world" do
    assert Stc.hello() == :world
  end
end
