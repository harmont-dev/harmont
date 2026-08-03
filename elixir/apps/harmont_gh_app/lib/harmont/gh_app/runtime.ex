defmodule Harmont.GhApp.Runtime do
  @moduledoc """
  Boot-time GitHub-App context. Centralizes the resolved `Settings`, the GitHub
  REST client constructor, and the installation-token lookup, so handlers and
  Oban workers never read global config directly.

  `Settings` is stashed in `:persistent_term` at boot (`put_settings/1`) and
  read back with `settings/0`.

  ## Test seam

  `github_client/1` merges `Application.get_env(:harmont_gh_app,
  :gh_app_github_req_options, [])` into the GitHub client's Req request. Tests
  set that app-env to `[plug: {Req.Test, GithubClient}]`
  so the stub intercepts; production leaves it `[]`.
  """

  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Settings

  @settings_key {__MODULE__, :settings}

  @doc "Stash the resolved Settings in `:persistent_term` (called once at boot)."
  @spec put_settings(Settings.t()) :: :ok
  def put_settings(%Settings{} = settings) do
    :persistent_term.put(@settings_key, settings)
  end

  @doc "Read back the Settings stashed by `put_settings/1`."
  @spec settings() :: Settings.t()
  def settings, do: :persistent_term.get(@settings_key)

  @doc """
  Safe variant of `settings/0`: `{:ok, settings}` when the GitHub App context
  has been booted, `:error` when it hasn't (e.g. dev without secrets). Lets the
  webhook plug fail cleanly (bland 500 + server-side log) instead of crashing on
  an unconfigured app.
  """
  @spec fetch_settings() :: {:ok, Settings.t()} | :error
  def fetch_settings do
    case :persistent_term.get(@settings_key, nil) do
      %Settings{} = s -> {:ok, s}
      _ -> :error
    end
  end

  @doc "The configured GitHub webhook secret, or nil if the app isn't configured."
  @spec webhook_secret() :: String.t() | nil
  def webhook_secret do
    case fetch_settings() do
      {:ok, settings} -> settings.webhook_secret
      :error -> nil
    end
  end

  @doc """
  Build a GitHub REST client for the given installation token, honoring the
  `:gh_app_github_req_options` test seam.
  """
  @spec github_client(String.t()) :: GithubClient.t()
  def github_client(token) do
    s = settings()

    GithubClient.new(
      base_url: s.github_api_base_url,
      token: token,
      req_options: github_req_options()
    )
  end

  @doc "Fetch (minting/refreshing as needed) the access token for an installation."
  @spec installation_token(integer()) :: {:ok, String.t()} | {:error, term()}
  def installation_token(installation_id),
    do: InstallationTokens.fetch(installation_id)

  defp github_req_options,
    do: Application.get_env(:harmont_gh_app, :gh_app_github_req_options, [])
end
