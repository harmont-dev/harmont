defmodule Harmont.GhApp.Store do
  @moduledoc """
  Database IO for the GitHub-App schemas. Holds every `Harmont.Repo` call
  so the schema modules under `Harmont.Github` stay pure.
  """
  import Ecto.Query
  alias Harmont.Repo

  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @provider "github"

  @doc """
  Insert-or-update a `vcs_installation` (provider "github") by its GitHub
  installation id (`installation.created`).

  Callers pass the GitHub installation **integer** as `:installation_id`; it is
  converted to the `external_id` STRING. A re-upsert resurrects a tombstoned
  install (see `Harmont.Vcs.upsert_installation/1`).
  """
  @spec upsert_installation(map()) ::
          {:ok, VcsInstallation.t()} | {:error, Ecto.Changeset.t()}
  def upsert_installation(attrs) do
    Vcs.upsert_installation(%{
      provider: @provider,
      external_id: to_string(attrs.installation_id),
      account_name: attrs.account_login,
      account_kind: attrs.account_type
    })
  end

  # NOTE: the legacy GitHub-vocabulary check-mapping functions
  # (create_check_run_mapping/1 + github_status_to_state/2, mark_check_run_status/3,
  # open_check_run_mappings/0, check_run_mapping_by_build_uuid/1) were DELETED in
  # the multi-provider cutover — they had zero production callers. The engine
  # creates checks via Vcs.create_provider_check, the reporter reconciles via
  # Vcs.open_provider_checks, and StatusUpdate looks up via
  # Vcs.provider_check_by_build_uuid. open_mappings_for_installation/1 below is the
  # only check-mapping reader still live (revoke teardown).

  @doc """
  List the mirrored `vcs_repo` rows (provider "github") for a GitHub
  installation id.

  `vcs_repo.installation_id` is a FK onto `vcs_installation.id`, so this joins
  through `vcs_installation` to resolve the GitHub installation id the internal
  endpoint receives. Returns `[]` for an unknown installation.
  """
  @spec list_repos_for_installation(integer()) :: [VcsRepo.t()]
  def list_repos_for_installation(github_installation_id) do
    Repo.all(
      from(r in VcsRepo,
        join: i in VcsInstallation,
        on: i.id == r.installation_id,
        where: i.provider == @provider and i.external_id == ^to_string(github_installation_id),
        order_by: r.full_name
      )
    )
  end

  @doc """
  List every non-deleted `vcs_installation` row (provider "github", ordered by
  id).

  Backs `GET /api/installations`, returning all installations with
  `deleted_at IS NULL`. harmont-api's `connectInstallation`
  filters this list by GitHub installation id, so returning the active set is
  correct (and excludes tombstoned installs that no longer exist on GitHub).
  """
  @spec list_installations() :: [VcsInstallation.t()]
  def list_installations do
    Repo.all(
      from(i in VcsInstallation,
        where: i.provider == @provider and is_nil(i.deleted_at),
        order_by: i.id
      )
    )
  end

  @doc "Look up a vcs_installation (provider \"github\") by its GitHub installation id (nil when absent)."
  @spec get_installation(integer()) :: VcsInstallation.t() | nil
  def get_installation(installation_id),
    do: Vcs.get_installation(@provider, to_string(installation_id))

  @doc "Soft-delete an installation by stamping deleted_at=now (no-op if absent)."
  @spec mark_installation_deleted(integer()) :: :ok
  def mark_installation_deleted(installation_id) do
    # The historical contract is `:ok` regardless of whether a row existed;
    # `Harmont.Vcs.mark_installation_deleted/2` returns {:error, :not_found}
    # when absent, which we fold back to `:ok`.
    _ = Vcs.mark_installation_deleted(@provider, to_string(installation_id))
    :ok
  end

  @doc "Set or clear an installation's suspended_at (suspend/unsuspend; no-op if absent)."
  @spec set_installation_suspended(integer(), boolean()) :: :ok
  def set_installation_suspended(installation_id, suspended?) do
    _ = Vcs.set_installation_suspended(@provider, to_string(installation_id), suspended?)
    :ok
  end

  @doc "All non-completed mappings for an installation (used to terminate on revoke)."
  @spec open_mappings_for_installation(integer()) :: [Harmont.Vcs.ProviderCheck.t()]
  def open_mappings_for_installation(installation_id) do
    target = to_string(installation_id)

    "github"
    |> Harmont.Vcs.open_provider_checks()
    |> Enum.filter(&(&1.installation_external_id == target))
  end

  # NOTE: the GitHub-specific delivery reserve/delete wrappers were removed when
  # the legacy `GhApp.Webhook.Handler` dedup path was deleted — the canonical
  # delivery reservation now lives in `Harmont.Apps.Webhook` (calling
  # `Harmont.Vcs.reserve_delivery/3` / `delete_delivery/2` directly). The
  # `webhook_delivery` pruning below is still used by the `DeliveryReaper` cron.

  @doc """
  Delete every `webhook_delivery` row received before `older_than`. Used by the
  `DeliveryReaper` cron to keep the dedup table from growing unbounded. The
  dedup window only needs to outlast GitHub's redelivery window (minutes to
  days), so old rows are safe to drop. Returns `{count, nil}`.
  """
  @spec prune_deliveries(DateTime.t()) :: {non_neg_integer(), nil}
  def prune_deliveries(older_than) do
    Harmont.Vcs.prune_deliveries("github", older_than)
  end

  @doc """
  The synced default branch for a repo, or `nil` if not mirrored.

  `vcs_repo.installation_id` is a FK onto `vcs_installation.id` (the internal
  bigserial PK), not the GitHub installation integer. This function accepts the
  GitHub installation integer and joins through `vcs_installation` to resolve it
  correctly — matching the pattern used by `list_repos_for_installation/1`.
  """
  @spec github_repo_default_branch(integer(), String.t()) :: String.t() | nil
  def github_repo_default_branch(github_installation_id, full_name) do
    Repo.one(
      from(r in VcsRepo,
        join: i in VcsInstallation,
        on: i.id == r.installation_id,
        where:
          i.provider == @provider and i.external_id == ^to_string(github_installation_id) and
            r.full_name == ^full_name,
        select: r.default_branch
      )
    )
  end
end
