defmodule Harmont.GhApp.SettingsTest do
  use ExUnit.Case, async: true
  alias Harmont.GhApp.Settings

  test "load rejects a short webhook secret" do
    env = base_env() |> Map.put("HARMONT_GITHUB_WEBHOOK_SECRET", "tooshort")
    assert {:error, msg} = Settings.load(env)
    assert msg =~ "WEBHOOK_SECRET"
  end

  test "load requires exactly one private-key source" do
    env =
      base_env() |> Map.drop(["HARMONT_GITHUB_PRIVATE_KEY", "HARMONT_GITHUB_PRIVATE_KEY_PATH"])

    assert {:error, _} = Settings.load(env)
  end

  test "load fills defaults" do
    assert {:ok, s} = Settings.load(base_env())
    assert s.github_api_base_url == "https://api.github.com"
    assert s.app_id == 42
  end

  test "non-integer HARMONT_GITHUB_APP_ID returns {:error} naming the var" do
    env = base_env() |> Map.put("HARMONT_GITHUB_APP_ID", "not_a_number")
    assert {:error, msg} = Settings.load(env)
    assert msg =~ "HARMONT_GITHUB_APP_ID"
    assert msg =~ "not_a_number"
  end

  test "HARMONT_GITHUB_APP_ID with trailing garbage (42abc) returns {:error}" do
    env = base_env() |> Map.put("HARMONT_GITHUB_APP_ID", "42abc")
    assert {:error, msg} = Settings.load(env)
    assert msg =~ "HARMONT_GITHUB_APP_ID"
    assert msg =~ "42abc"
  end

  test "HARMONT_GITHUB_APP_ID tolerates surrounding whitespace (regression: \"3492158 \")" do
    # A Secret Manager value with a stray trailing space crash-looped the node
    # in prod. Whitespace must now be trimmed, not rejected.
    env = base_env() |> Map.put("HARMONT_GITHUB_APP_ID", " 3492158 \n")
    assert {:ok, s} = Settings.load(env)
    assert s.app_id == 3_492_158
  end

  test "non-integer HARMONT_GITHUB_HTTP_TIMEOUT_SECONDS returns {:error} naming the var" do
    env = base_env() |> Map.put("HARMONT_GITHUB_HTTP_TIMEOUT_SECONDS", "fast")
    assert {:error, msg} = Settings.load(env)
    assert msg =~ "HARMONT_GITHUB_HTTP_TIMEOUT_SECONDS"
    assert msg =~ "fast"
  end

  test "unreadable HARMONT_GITHUB_PRIVATE_KEY_PATH returns {:error} without raising" do
    env =
      base_env()
      |> Map.drop(["HARMONT_GITHUB_PRIVATE_KEY"])
      |> Map.put("HARMONT_GITHUB_PRIVATE_KEY_PATH", "/nonexistent/key.pem")

    assert {:error, msg} = Settings.load(env)
    assert msg =~ "HARMONT_GITHUB_PRIVATE_KEY_PATH"
    assert msg =~ "/nonexistent/key.pem"
  end

  defp base_env do
    %{
      "HARMONT_GITHUB_APP_ID" => "42",
      "HARMONT_GITHUB_WEBHOOK_SECRET" => String.duplicate("x", 20),
      "HARMONT_GITHUB_PRIVATE_KEY" => "-----BEGIN RSA PRIVATE KEY-----\n..."
    }
  end
end
