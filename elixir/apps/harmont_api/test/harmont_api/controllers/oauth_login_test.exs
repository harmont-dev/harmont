defmodule HarmontApi.Controllers.OAuthLoginTest do
  @moduledoc """
  `describe/1` summarizes an OAuth failure for the logs. Assent error structs
  embed the full strategy config — including the OAuth `client_secret` — so they
  must never be `inspect/1`'d into a log line. These guard that redaction.
  """
  use ExUnit.Case, async: true

  alias HarmontApi.Controllers.OAuthLogin

  test "redacts the client_secret carried in an Assent.MissingConfigError" do
    err = %Assent.MissingConfigError{
      key: :session_params,
      config: [client_id: "id", client_secret: "GOCSPX-supersecret"]
    }

    summary = OAuthLogin.describe(err)

    refute summary =~ "GOCSPX-supersecret"
    assert summary =~ "session_params"
  end

  test "renders other exceptions via their message, not a struct dump" do
    summary = OAuthLogin.describe(%RuntimeError{message: "boom"})
    assert summary =~ "RuntimeError"
    assert summary =~ "boom"
  end

  test "inspects plain (non-exception) reasons" do
    assert OAuthLogin.describe({:oauth_not_configured, :google}) ==
             "{:oauth_not_configured, :google}"

    assert OAuthLogin.describe(:no_email) == ":no_email"
  end
end
