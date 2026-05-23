defmodule DllbTest do
  use ExUnit.Case
  doctest Dllb

  test "greets the world" do
    assert Dllb.hello() == :world
  end
end
