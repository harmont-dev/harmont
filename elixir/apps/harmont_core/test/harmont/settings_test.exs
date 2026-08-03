defmodule Harmont.SettingsTest do
  use Harmont.DataCase, async: true

  alias Harmont.Settings

  describe "get/put" do
    test "get returns nil for an absent key" do
      assert Settings.get("nope", Repo) == nil
    end

    test "put inserts then get reads it back" do
      assert {:ok, _} = Settings.put("greeting", "hi", Repo)
      assert Settings.get("greeting", Repo) == "hi"
    end

    test "put upserts: second put for the same key replaces the value" do
      {:ok, _} = Settings.put("k", "one", Repo)
      {:ok, _} = Settings.put("k", "two", Repo)

      assert Settings.get("k", Repo) == "two"
    end
  end

  describe "signup_cap/put_signup_cap" do
    test "signup_cap is nil when unset (unlimited)" do
      assert Settings.signup_cap(Repo) == nil
    end

    test "put_signup_cap then signup_cap round-trips as an integer" do
      {:ok, _} = Settings.put_signup_cap(500, Repo)
      assert Settings.signup_cap(Repo) == 500
    end

    test "a non-numeric stored value reads back as nil (treated as unset)" do
      {:ok, _} = Settings.put("signup_cap", "banana", Repo)
      assert Settings.signup_cap(Repo) == nil
    end

    test "a numeric value with trailing garbage reads back as nil" do
      {:ok, _} = Settings.put("signup_cap", "100abc", Repo)
      assert Settings.signup_cap(Repo) == nil
    end
  end
end
