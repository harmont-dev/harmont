defmodule Harmont.GhApp.Application do
  @moduledoc false
  use Application

  require Logger

  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Installations
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings

  @impl true
  def start(_type, _args) do
    children = gh_app_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Harmont.GhApp.Supervisor)
  end

  @doc false
  # Build the GitHub-App child specs from the environment. Loads + validates
  # Settings, stashes them in Runtime, and returns the InstallationTokens
  # cache (wired to the production mint fun). The build-status reporter is the
  # provider-agnostic `Harmont.Apps.Reporter`, supervised by `harmont_apps`.
  # When secrets are absent: dev/test (`:gh_app_required` false) boot without
  # the subtree; prod (`:gh_app_required` true) refuses to boot.
  def gh_app_children(env \\ System.get_env()) do
    case Settings.load(env) do
      {:ok, settings} ->
        require_internal_token!(settings)
        Runtime.put_settings(settings)

        # Register GitHub with the provider-agnostic apps layer (the generic
        # `/webhooks/:provider` plug + ProcessDelivery worker). Merge-registers
        # over whatever is in config so the wiring holds even if app env was
        # overridden at runtime. Mirrors the static fallback in config.exs.
        Application.put_env(
          :harmont_apps,
          :providers,
          Keyword.put(
            Application.get_env(:harmont_apps, :providers, []),
            :github,
            Harmont.GhApp.Provider
          )
        )

        Application.put_env(
          :harmont_apps,
          :secrets,
          Keyword.put(
            Application.get_env(:harmont_apps, :secrets, []),
            :github,
            {Harmont.GhApp.Runtime, :webhook_secret}
          )
        )

        [
          {InstallationTokens,
           app_id: settings.app_id,
           private_key_pem: settings.private_key_pem,
           github_base_url: settings.github_api_base_url},
          # Self-heal: reconcile the github_installation table against GitHub's
          # authoritative listing once at boot. A :temporary Task — it runs
          # once, never restarts, and reconcile_on_boot/0 swallows all errors,
          # so a GitHub hiccup can't crash or block the supervisor. Recreates a
          # missing installation row (e.g. lost in a migration) instead of
          # 503-storming every webhook forever.
          Supervisor.child_spec({Task, &Installations.reconcile_on_boot/0},
            id: :gh_app_installations_reconcile,
            restart: :temporary
          )
        ]

      {:error, msg} ->
        Logger.error("GitHub App config error: #{msg}")

        if Application.get_env(:harmont_gh_app, :gh_app_required, false) do
          raise "GitHub App misconfigured: #{msg}"
        else
          []
        end
    end
  end

  # In prod (`:gh_app_required`), the internal GitHub proxy token MUST be set.
  # A nil/empty token makes HarmontWeb.GithubInternal.authorized?/2 fail OPEN,
  # serving /api/installations + the file proxy unauthenticated on the public
  # edge. Fail closed at boot instead — mirrors the required GitHub-App secrets.
  defp require_internal_token!(%Settings{internal_token: token})
       when is_binary(token) and token != "" do
    :ok
  end

  defp require_internal_token!(_settings) do
    if Application.get_env(:harmont_gh_app, :gh_app_required, false) do
      raise "HARMONT_GITHUB_INTERNAL_TOKEN is required in prod: without it the internal GitHub proxy endpoints (/api/installations, file proxy) serve unauthenticated. Set it to a strong random secret."
    else
      :ok
    end
  end
end
