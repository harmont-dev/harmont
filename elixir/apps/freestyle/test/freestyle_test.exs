defmodule FreestyleTest do
  use ExUnit.Case, async: true

  test "version/0 returns the library version" do
    assert Freestyle.version() == "0.1.0"
  end
end
