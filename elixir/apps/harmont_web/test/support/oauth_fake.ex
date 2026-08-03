defmodule HarmontWeb.Support.OAuthFake do
  @moduledoc """
  Test fake for `HarmontApi.OAuth`, used by the end-to-end auth integration
  test that drives a full login flow through the real `HarmontWeb.Endpoint`.

  harmont_api's own `HarmontApi.OAuthFake` lives in that app's `test/support`
  and is therefore not compiled when the harmont_web test suite runs, so this
  app carries its own equivalent. The e2e test wires it in for the duration of
  the test via `Application.put_env(:harmont_api, :oauth_impl, ...)`.

  A `code` of `"ok:<email>"` yields a canned `{:ok, %{provider_id, email,
  name}}`; everything else is a provider error.
  """

  def fetch_user(provider, %{code: "ok:" <> email}) do
    {:ok,
     %{
       provider_id: "#{provider}-#{:erlang.phash2(email)}",
       email: email,
       name: "E2E User"
     }}
  end

  def fetch_user(_provider, _params), do: {:error, :provider_rejected}
end
