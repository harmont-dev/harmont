defmodule HarmontApi.OAuth do
  @moduledoc """
  The real Assent-backed OAuth user fetcher for Google and GitHub.

  The SPA performs the provider redirect and hands us the authorization `code`
  plus the `redirect_uri` it used. We exchange that code and fetch
  the provider's userinfo via Assent, then normalize it to the minimal shape the
  controllers need:

      {:ok, %{provider_id: String.t(), email: String.t(), name: String.t() | nil}}

  ## Indirection for tests

  Controllers don't call this module directly — they call
  `oauth_impl().fetch_user/2` (see `HarmontApi.Controllers.OAuthLogin`), where
  `:oauth_impl` defaults to this module and tests set
  `config :harmont_api, :oauth_impl, HarmontApi.OAuthFake` to supply canned
  results without real HTTP. So the swap lives entirely at the call site; this
  module's `fetch_user/2` is always the real Assent path and must not re-read
  `:oauth_impl` (that would recurse into itself).

  ## Provider details

  - **Google** — Assent's Google strategy returns OpenID Connect userinfo; the
    stable subject is `"sub"`, which we use as `provider_id`.
  - **GitHub** — Assent's GitHub strategy requests the `user:email` scope and
    fetches the primary verified email into `"email"`. The numeric `"sub"`
    (GitHub's `id`) becomes `provider_id` (stringified). If GitHub returns no
    usable email, we surface `{:error, :no_email}`.
  """

  alias Assent.Strategy.Github
  alias Assent.Strategy.Google

  @type provider :: :google | :github
  @type params :: %{required(:code) => String.t(), optional(:redirect_uri) => String.t()}
  @type user :: %{provider_id: String.t(), email: String.t(), name: String.t() | nil}

  defmodule Behaviour do
    @moduledoc """
    The OAuth user-fetch contract shared by `HarmontApi.OAuth` and test fakes.

    Anything wired in via `config :harmont_api, :oauth_impl` must implement it.
    """
    @callback fetch_user(HarmontApi.OAuth.provider(), HarmontApi.OAuth.params()) ::
                {:ok, HarmontApi.OAuth.user()} | {:error, term()}
  end

  @behaviour Behaviour

  @doc """
  Fetches and normalizes the provider user for `provider` via the real Assent
  exchange — swaps `code` for the provider's userinfo and reshapes it.

  The test/fake swap happens one level up: callers reach the fetcher through
  `:oauth_impl` (see `HarmontApi.Controllers.OAuthLogin`), which defaults to
  this module and is overridden to `HarmontApi.OAuthFake` in tests. This
  function must NOT dispatch through `:oauth_impl` again — that key defaults
  back to this module, so doing so makes it call itself forever (the bug that
  hung every real sign-in: the request blocked with no exchange, no error, and
  no response).
  """
  @impl Behaviour
  @spec fetch_user(provider(), params()) :: {:ok, user()} | {:error, term()}
  def fetch_user(provider, params) do
    with {:ok, config} <- config_for(provider, params),
         {:ok, %{user: claims}} <- strategy(provider).callback(config, callback_params(params)) do
      normalize(provider, claims)
    end
  end

  @doc false
  # Build the Assent config from app env. Internal, but public (not defp) so it
  # can be unit-tested without driving a real HTTP exchange. Returns a typed
  # error if the provider is unconfigured.
  #
  # Two Assent keys matter for our SPA-driven flow:
  #
  #   * `state: false` — disable Assent's server-side CSRF `state` check. The SPA
  #     performs the authorize redirect itself, and its popup helper verifies the
  #     returned `state` against the one it issued *before* it ever calls this
  #     backend. The backend only does the code→token exchange and never receives
  #     the `state`, so there is nothing for Assent to compare. Without this,
  #     `Assent.Strategy.OAuth2.verify_state/3` does `session_params.state` and
  #     crashes with `KeyError key :state`.
  #   * `session_params: %{}` — `callback/2` still requires the key to be present
  #     (`Assent.fetch_config(config, :session_params)`); we have no
  #     server-issued params (no PKCE either), so an empty map satisfies it.
  #     Omitting it raises `%Assent.MissingConfigError{key: :session_params}`.
  @spec config_for(provider(), params()) :: {:ok, keyword()} | {:error, term()}
  def config_for(provider, params) do
    case Application.get_env(:harmont_api, :oauth)[provider] do
      nil ->
        {:error, {:oauth_not_configured, provider}}

      base ->
        {:ok,
         base
         |> with_redirect_uri(params)
         |> Keyword.put(:session_params, %{})
         |> Keyword.put(:state, false)}
    end
  end

  # Both Google and GitHub need redirect_uri in the Assent config: Assent's
  # OAuth2 authorization_code exchange (fetch_grant_access_token_params/3)
  # fetches :redirect_uri from config BEFORE the token request and returns
  # %Assent.MissingConfigError{key: :redirect_uri} without it — instantly, with
  # no HTTP. The SPA passes the same redirect_uri it used on the authorize step.
  defp with_redirect_uri(base, %{redirect_uri: redirect_uri}) when is_binary(redirect_uri) do
    Keyword.put(base, :redirect_uri, redirect_uri)
  end

  defp with_redirect_uri(base, _params), do: base

  defp callback_params(%{code: code}), do: %{"code" => code}

  defp strategy(:google), do: Google
  defp strategy(:github), do: Github

  defp normalize(:google, %{"sub" => sub} = claims) when not is_nil(sub) do
    {:ok,
     %{
       provider_id: to_string(sub),
       email: claims["email"],
       name: claims["name"]
     }}
  end

  defp normalize(:github, %{"sub" => sub} = claims) when not is_nil(sub) do
    case claims["email"] do
      email when is_binary(email) and email != "" ->
        {:ok, %{provider_id: to_string(sub), email: email, name: claims["name"]}}

      _ ->
        {:error, :no_email}
    end
  end

  defp normalize(_provider, _claims), do: {:error, :missing_provider_id}
end
