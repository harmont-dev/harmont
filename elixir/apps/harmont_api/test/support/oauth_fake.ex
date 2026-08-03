defmodule HarmontApi.OAuthFake do
  @moduledoc """
  Test fake for `HarmontApi.OAuth`.

  Wired in via `config :harmont_api, :oauth_impl, HarmontApi.OAuthFake` (test
  env). It returns canned `{:ok, %{provider_id, email, name}}` keyed off the
  `code` param so a single test can drive the allowed / denied / provider-error
  branches deterministically, with no real HTTP:

  - `code` starting with `"ok:"` — success; the email after the prefix is used
    (e.g. `"ok:alice@harmont.dev"`), letting tests pick gate-allowed vs denied
    emails. `provider_id` derives from the provider + email; `name` is canned.
  - `code == "error"` — returns `{:error, :provider_rejected}` to exercise the
    upstream-failure branch.
  - anything else — `{:error, :unexpected_code}`.
  """

  # Intentionally does not `@behaviour HarmontApi.OAuth.Behaviour`: the real
  # module carries the contract, and depending on the nested behaviour module
  # here makes test/support compilation sensitive to lib compile order. This
  # fake just needs a matching `fetch_user/2`.

  def fetch_user(provider, %{code: "ok:" <> email}) do
    {:ok,
     %{
       provider_id: "#{provider}-#{:erlang.phash2(email)}",
       email: email,
       name: "Test User"
     }}
  end

  def fetch_user(_provider, %{code: "error"}), do: {:error, :provider_rejected}
  def fetch_user(_provider, _params), do: {:error, :unexpected_code}
end
