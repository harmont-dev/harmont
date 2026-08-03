defmodule Harmont.GhApp.Installations do
  @moduledoc """
  Reconcile the `github_installation` table against GitHub's authoritative list.

  The webhook path only learns about an installation from the
  `installation.created` event (`Handler.handle_installation/1` →
  `Store.upsert_installation`). If that event is missed — a delivery dropped, or
  the row lost in a data migration — every later webhook for that installation
  hits the `nil` guard in `with_active_installation/2`, returns `503`, and Oban
  retries it to exhaustion. No build is ever created, and there is no self-heal:
  GitHub does not resend `installation.created`.

  The App JWT can always list the App's installations (`GET /app/installations`),
  so that listing is the source of truth. `reconcile_on_boot/0` runs this at
  startup (best-effort, never blocks or crashes boot), so a missing row is
  recreated on the next deploy/restart instead of 503-storming forever.

  Reconcile is **additive**: it upserts the active installations GitHub reports
  and never deletes local rows (a transient API blip must not tombstone live
  installs). Suspended installations are skipped so a stale listing can't
  silently un-suspend one — a real `installation.unsuspend` webhook owns that
  transition.
  """
  require Logger

  alias Harmont.GhApp.GitHub.Jwt
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Store

  @doc """
  Best-effort boot reconcile: log the outcome, never raise. A no-op when the
  GitHub App context isn't configured (dev/test without secrets).
  """
  @spec reconcile_on_boot() :: :ok
  def reconcile_on_boot do
    case reconcile() do
      {:ok, n} ->
        Logger.info("gh-app: reconciled #{n} installation(s) from GitHub")

      {:error, :not_configured} ->
        :ok

      {:error, reason} ->
        Logger.error("gh-app: installation reconcile failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Mint an App JWT, list the App's installations from GitHub, and upsert the
  active ones. Returns `{:ok, upserted_count}` or `{:error, reason}`
  (`:not_configured` when the GitHub App context hasn't booted).
  """
  @spec reconcile() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile do
    with {:ok, client} <- app_client() do
      reconcile_with(client)
    end
  end

  @doc """
  Reconcile against an already-built App-JWT `GithubClient`. Separated from
  `reconcile/0` so tests can inject a stubbed client (no JWT/network).
  """
  @spec reconcile_with(GithubClient.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_with(%GithubClient{} = client) do
    with {:ok, installations} <- GithubClient.list_app_installations(client) do
      count =
        installations
        |> Enum.reject(& &1.suspended_at)
        |> Enum.count(fn i ->
          match?(
            {:ok, _},
            Store.upsert_installation(%{
              installation_id: i.installation_id,
              account_login: i.account_login,
              account_type: i.account_type
            })
          )
        end)

      {:ok, count}
    end
  end

  # Build a GitHub client authed with a freshly-minted App JWT. Returns
  # {:error, :not_configured} when Settings haven't been stashed (dev/test).
  defp app_client do
    with {:ok, settings} <- Runtime.fetch_settings(),
         {:ok, jwt} <- Jwt.mint(settings.private_key_pem, settings.app_id, DateTime.utc_now()) do
      {:ok, Runtime.github_client(jwt)}
    else
      :error -> {:error, :not_configured}
      {:error, _} = err -> err
    end
  end
end
