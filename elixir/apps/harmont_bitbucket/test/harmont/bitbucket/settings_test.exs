defmodule Harmont.Bitbucket.SettingsTest do
  use ExUnit.Case, async: true
  alias Harmont.Bitbucket.Settings

  test "load/1 requires client_id, client_secret, webhook_secret(>=20)" do
    env = %{
      "HARMONT_BITBUCKET_CLIENT_ID" => "cid",
      "HARMONT_BITBUCKET_CLIENT_SECRET" => "csecret",
      "HARMONT_BITBUCKET_WEBHOOK_SECRET" => String.duplicate("x", 20)
    }

    assert {:ok, %Settings{client_id: "cid"}} = Settings.load(env)
  end

  test "load/1 errors on short webhook secret" do
    env = %{
      "HARMONT_BITBUCKET_CLIENT_ID" => "cid",
      "HARMONT_BITBUCKET_CLIENT_SECRET" => "csecret",
      "HARMONT_BITBUCKET_WEBHOOK_SECRET" => "short"
    }

    assert {:error, _} = Settings.load(env)
  end

  test "secrets are redacted from inspect" do
    {:ok, s} =
      Settings.load(%{
        "HARMONT_BITBUCKET_CLIENT_ID" => "cid",
        "HARMONT_BITBUCKET_CLIENT_SECRET" => "csecret",
        "HARMONT_BITBUCKET_WEBHOOK_SECRET" => String.duplicate("x", 20)
      })

    refute inspect(s) =~ "csecret"
  end
end
