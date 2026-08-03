defmodule Harmont.ObanSmartEngineTest do
  use Harmont.DataCase, async: true

  test "Oban runs on the Pro Smart engine" do
    assert Oban.config().engine == Oban.Pro.Engines.Smart
  end
end
