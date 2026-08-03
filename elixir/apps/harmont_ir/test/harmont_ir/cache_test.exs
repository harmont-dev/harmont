defmodule HarmontIr.CacheTest do
  use ExUnit.Case, async: true
  alias HarmontIr.Cache

  test "from_map/1 happy path with policy and key" do
    assert {:ok, %Cache{policy: "content-hash", key: "k1"}} =
             Cache.from_map(%{"policy" => "content-hash", "key" => "k1"})
  end

  test "from_map/1 happy path with policy only, key defaults to nil" do
    assert {:ok, %Cache{policy: "p", key: nil}} = Cache.from_map(%{"policy" => "p"})
  end

  test "from_map/1 returns missing_field error when policy is absent" do
    assert {:error, {:missing_field, "policy"}} = Cache.from_map(%{})
  end
end
