defmodule Harmont.GhApp.Lifecycle do
  @moduledoc """
  GitHub installation/repo lifecycle side effects, absorbed from the retired
  `Harmont.GhApp.Webhook.Handler` installation/`installation_repositories`
  handlers. Invoked from `Harmont.GhApp.Provider.apply_lifecycle/2`, which the
  canonical `Harmont.Apps.Engine` routes lifecycle Events to.

  The neutral `Harmont.Apps.Event` carries the GitHub installation id as a string
  (`installation_external_id`) and the GitHub-specific payload bits (account
  login/type, removed repos) in `raw`. Each lifecycle kind maps to one of:

    * `:installation_added` — upsert/resurrect the `vcs_installation` row, then
      enqueue a durable repo sync.
    * `:installation_removed` — terminate open checks FIRST (so the reporter stops
      touching GitHub), then tombstone the install.
    * `:installation_suspended` / `:installation_unsuspended` — flip
      `suspended_at`.
    * `:repos_changed` — terminate open checks for any removed repos, then
      enqueue a repo sync to reconcile the mirror.

  Reads `installation_map.account_login` / `.account_type` from the GitHub wire
  projection and writes them through `Harmont.Vcs.upsert_installation/1` (the
  provider-neutral installation persistence). Returns `:ok` (best-effort
  enqueues are logged on failure, never raised — a lifecycle ack must not be
  blocked); a hard upsert failure surfaces as `{:error, _}` so the engine maps
  it to a retry.
  """
  require Logger

  alias Harmont.Apps.Event
  alias Harmont.GhApp.Webhook.SyncRepos
  alias Harmont.Vcs

  @provider "github"

  @spec apply(Event.t()) :: :ok | {:error, term()}
  def apply(%Event{kind: :installation_added, installation_external_id: ext, raw: raw}) do
    case Vcs.upsert_installation(%{
           provider: @provider,
           external_id: ext,
           account_name: raw["account_login"],
           account_kind: raw["account_type"]
         }) do
      {:ok, _} ->
        safe_trigger_sync(ext)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply(%Event{kind: :installation_removed, installation_external_id: ext}) do
    # Terminate open checks FIRST (matches the legacy ordering), then tombstone.
    ext
    |> open_checks()
    |> terminate_open_checks()

    _ = Vcs.mark_installation_deleted(@provider, ext)
    :ok
  end

  def apply(%Event{kind: :installation_suspended, installation_external_id: ext}) do
    _ = Vcs.set_installation_suspended(@provider, ext, true)
    :ok
  end

  def apply(%Event{kind: :installation_unsuspended, installation_external_id: ext}) do
    _ = Vcs.set_installation_suspended(@provider, ext, false)
    :ok
  end

  def apply(%Event{kind: :repos_changed, installation_external_id: ext, raw: raw}) do
    removed =
      raw
      |> Map.get("repositories_removed", [])
      |> MapSet.new(fn r -> {r["owner"], r["repo"]} end)

    if MapSet.size(removed) > 0 do
      ext
      |> open_checks()
      |> Enum.filter(fn c -> MapSet.member?(removed, {c.owner, c.repo}) end)
      |> terminate_open_checks()
    end

    safe_trigger_sync(ext)
    :ok
  end

  def apply(%Event{}), do: :ok

  ## ---- helpers ----

  # All non-terminal checks for this installation (provider "github").
  defp open_checks(external_id) do
    @provider
    |> Vcs.open_provider_checks()
    |> Enum.filter(&(&1.installation_external_id == external_id))
  end

  # Close each open check with a neutral conclusion (revoke / repo-removal). This
  # is local-only housekeeping to stop the reporter: once the install is gone we
  # have no token to PATCH GitHub, and GitHub auto-resolves an uninstalled app's
  # check runs anyway, so we only update our own DB.
  defp terminate_open_checks(checks) do
    Enum.each(checks, fn c ->
      case Vcs.mark_provider_check_state(c, %{phase: :neutral}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("gh-app: failed to terminate check #{c.build_uuid}: #{inspect(reason)}")
      end
    end)
  end

  # Enqueue a durable repo sync on the `:gh_app` queue. SyncRepos expects the
  # GitHub installation INTEGER; the Event carries it as a string. Best-effort:
  # a webhook ack must not be blocked, so a failed insert is logged and dropped
  # (the next webhook re-enqueues and the reporter's reconcile is a backstop).
  defp safe_trigger_sync(external_id) do
    case Integer.parse(external_id) do
      {installation_id, ""} ->
        do_trigger_sync(installation_id)

      _ ->
        Logger.warning(
          "gh-app: skipping repo sync — installation_external_id #{inspect(external_id)} " <>
            "is not a GitHub installation id"
        )

        :ok
    end
  end

  defp do_trigger_sync(installation_id) do
    case %{"installation_id" => installation_id} |> SyncRepos.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "gh-app: failed to enqueue installation repo sync for installation " <>
            "#{installation_id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
