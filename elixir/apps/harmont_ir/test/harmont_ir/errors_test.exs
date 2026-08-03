defmodule HarmontIr.ErrorsTest do
  use ExUnit.Case, async: true
  alias HarmontIr.PlanError

  describe "message/1 renders each PlanError variant" do
    test "duplicate_key names the offending key" do
      assert PlanError.message({:duplicate_key, "a"}) =~ "a"
      assert PlanError.message({:duplicate_key, "a"}) =~ "duplicate"
    end

    test "unknown_dependency names both the source and the missing target" do
      msg = PlanError.message({:unknown_dependency, "b", "z"})
      assert msg =~ "b"
      assert msg =~ "z"
      assert msg =~ "unknown"
    end

    test "cycle names the cycle and its keys" do
      msg = PlanError.message({:cycle, ["a", "b"]})
      assert msg =~ "cycle"
      assert msg =~ "a"
      assert msg =~ "b"
    end
  end
end
