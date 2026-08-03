defmodule HarmontWebTest do
  use ExUnit.Case
  doctest HarmontWeb

  test "greets the world" do
    assert HarmontWeb.hello() == :world
  end
end
