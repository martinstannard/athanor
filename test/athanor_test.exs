defmodule AthanorTest do
  use ExUnit.Case
  doctest Athanor

  test "greets the world" do
    assert Athanor.hello() == :world
  end
end
