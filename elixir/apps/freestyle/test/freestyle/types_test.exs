defmodule Freestyle.TypesTest do
  use ExUnit.Case, async: true

  test "default_page_params is limit 50, offset 0" do
    assert Freestyle.Types.default_page_params() == %{limit: 50, offset: 0}
  end
end
