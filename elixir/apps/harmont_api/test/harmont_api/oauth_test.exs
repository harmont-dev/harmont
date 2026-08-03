defmodule HarmontApi.OAuthTest do
  @moduledoc """
  Guards the real OAuth fetcher against the self-recursion regression.

  In prod `:oauth_impl` is unset, so `OAuthLogin` calls
  `HarmontApi.OAuth.fetch_user/2` directly. That function once re-read
  `:oauth_impl` itself — which defaults back to this module — so it called
  itself forever and hung every real Google/GitHub sign-in (no exchange, no
  error, no response). Every other test swaps in `OAuthFake`, so only a direct
  call to the real module exercises this path.
  """
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:harmont_api, :oauth)
    on_exit(fn -> Application.put_env(:harmont_api, :oauth, prev) end)
    :ok
  end

  test "fetch_user reaches the real config path (does not recurse) when a provider is unconfigured" do
    # With no providers configured, config_for/2 short-circuits with the typed
    # error before any HTTP. If fetch_user still dispatched through :oauth_impl
    # it would recurse into itself and never return — reaching these assertions
    # proves it runs the real code exactly once.
    Application.put_env(:harmont_api, :oauth, [])

    assert HarmontApi.OAuth.fetch_user(:google, %{code: "x", redirect_uri: "https://app/cb"}) ==
             {:error, {:oauth_not_configured, :google}}

    assert HarmontApi.OAuth.fetch_user(:github, %{code: "x"}) ==
             {:error, {:oauth_not_configured, :github}}
  end

  test "config_for/2 supplies :session_params and the SPA redirect_uri" do
    # Assent's OAuth2 callback/2 raises %Assent.MissingConfigError{key:
    # :session_params} without this key, which broke every real sign-in. The SPA
    # owns the authorize step + CSRF state, so the backend exchange passes %{}.
    Application.put_env(:harmont_api, :oauth, google: [client_id: "id", client_secret: "secret"])

    assert {:ok, config} =
             HarmontApi.OAuth.config_for(:google, %{
               code: "c",
               redirect_uri: "https://app.harmont.dev/auth/callback"
             })

    assert Keyword.fetch!(config, :session_params) == %{}
    # state: false — the SPA owns CSRF state; without it Assent's verify_state
    # does session_params.state and crashes with KeyError :state.
    assert Keyword.fetch!(config, :state) == false
    assert Keyword.fetch!(config, :redirect_uri) == "https://app.harmont.dev/auth/callback"
    assert Keyword.fetch!(config, :client_id) == "id"
  end

  test "config_for/2 includes the SPA redirect_uri for GitHub too" do
    # Regression: Assent's OAuth2 authorization_code exchange fetches
    # :redirect_uri from config (fetch_grant_access_token_params/3) BEFORE any
    # HTTP, for every provider. GitHub config used to omit it, so every GitHub
    # sign-in failed instantly with %Assent.MissingConfigError{key: :redirect_uri}
    # → 502 oauth_provider_error.
    Application.put_env(:harmont_api, :oauth, github: [client_id: "id", client_secret: "secret"])

    assert {:ok, config} =
             HarmontApi.OAuth.config_for(:github, %{
               code: "c",
               redirect_uri: "https://app.harmont.dev/auth/callback"
             })

    assert Keyword.fetch!(config, :redirect_uri) == "https://app.harmont.dev/auth/callback"
    assert Keyword.fetch!(config, :session_params) == %{}
    assert Keyword.fetch!(config, :state) == false
    assert Keyword.fetch!(config, :client_id) == "id"
  end
end
