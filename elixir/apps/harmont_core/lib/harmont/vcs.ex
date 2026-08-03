defmodule Harmont.Vcs do
  @moduledoc """
  Persistence context for the provider-agnostic VCS tables
  (`vcs_installation`, `vcs_repo`, `vcs_provider_check`, `vcs_webhook_delivery`).

  Every function is keyed by `provider` (a string, e.g. "github") so each
  provider's storage layer (GitHub's `Harmont.GhApp.Store`, Bitbucket's later)
  delegates here unchanged. All DB IO for these tables lives in this module —
  the schemas are pure.

  Note the name overlap: the schema `Harmont.Vcs.Repo` is aliased as `VcsRepo`;
  `Repo` refers to the Ecto repo `Harmont.Repo`.
  """
  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Harmont.Repo
  alias Harmont.Vcs.{Installation, ProviderCheck, WebhookDelivery}
  alias Harmont.Vcs.Repo, as: VcsRepo

  ## ---- Deliveries (dedup) ----

  @doc "Reserve a delivery id; :ok if new, :duplicate if already seen for this provider."
  @spec reserve_delivery(String.t(), String.t(), String.t()) :: :ok | :duplicate
  def reserve_delivery(provider, delivery_id, event) do
    attrs = %{
      provider: provider,
      delivery_id: delivery_id,
      event: event,
      received_at: DateTime.utc_now()
    }

    case attrs |> WebhookDelivery.changeset() |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, _changeset} -> :duplicate
    end
  end

  @doc "Delete a reserved delivery (rollback when the enqueue fails)."
  @spec delete_delivery(String.t(), String.t()) :: :ok
  def delete_delivery(provider, delivery_id) do
    from(d in WebhookDelivery, where: d.provider == ^provider and d.delivery_id == ^delivery_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "Prune deliveries older than the given cutoff for a provider."
  @spec prune_deliveries(String.t(), DateTime.t()) :: {non_neg_integer(), nil}
  def prune_deliveries(provider, %DateTime{} = older_than) do
    from(d in WebhookDelivery,
      where: d.provider == ^provider and d.received_at < ^older_than
    )
    |> Repo.delete_all()
  end

  @doc """
  Prune deliveries older than the given cutoff across ALL providers.

  The dedup table is provider-agnostic; every provider (GitHub, Bitbucket, …)
  inserts rows here, so the reaper must reap every provider's rows, not just
  GitHub's. Single statement — no per-provider filter.
  """
  @spec prune_deliveries(DateTime.t()) :: {non_neg_integer(), nil}
  def prune_deliveries(%DateTime{} = older_than) do
    from(d in WebhookDelivery, where: d.received_at < ^older_than)
    |> Repo.delete_all()
  end

  ## ---- Installations ----

  @doc """
  Upsert an installation's webhook-driven identity (by provider+external_id).

  A re-upsert (a fresh `installation.created` after a prior delete/suspend)
  **resurrects** a tombstoned row: `deleted_at`/`suspended_at` reset to nil so
  the install is active again. `created_at` is preserved (not in the replace
  list); `updated_at` advances.
  """
  @spec upsert_installation(map()) :: {:ok, Installation.t()} | {:error, Ecto.Changeset.t()}
  def upsert_installation(attrs) do
    attrs
    |> Installation.upsert_changeset()
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:account_name, :account_kind, :provider_data, :updated_at, :deleted_at, :suspended_at]},
      conflict_target: [:provider, :external_id],
      returning: true
    )
  end

  @doc "Fetch an installation by provider + external id."
  @spec get_installation(String.t(), String.t()) :: Installation.t() | nil
  def get_installation(provider, external_id) do
    Repo.get_by(Installation, provider: provider, external_id: external_id)
  end

  @spec set_installation_suspended(String.t(), String.t(), boolean()) ::
          {:ok, Installation.t()} | {:error, :not_found}
  def set_installation_suspended(provider, external_id, suspended?) do
    case get_installation(provider, external_id) do
      %Installation{} = inst ->
        at = if suspended?, do: DateTime.utc_now(), else: nil
        inst |> Ecto.Changeset.change(suspended_at: at) |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  @spec mark_installation_deleted(String.t(), String.t()) ::
          {:ok, Installation.t()} | {:error, :not_found}
  def mark_installation_deleted(provider, external_id) do
    case get_installation(provider, external_id) do
      %Installation{} = inst ->
        inst |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Encrypt + persist an OAuth credentials bundle (a JSON-able map) for an installation."
  @spec put_credentials(String.t(), String.t(), map()) ::
          {:ok, Installation.t()} | {:error, term()}
  def put_credentials(provider, external_id, bundle) when is_map(bundle) do
    case get_installation(provider, external_id) do
      %Installation{} = inst ->
        inst
        |> Ecto.Changeset.change(credentials_encrypted: Jason.encode!(bundle))
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Read + decrypt the OAuth credentials bundle, or nil if absent."
  @spec get_credentials(String.t(), String.t()) :: map() | nil
  def get_credentials(provider, external_id) do
    case get_installation(provider, external_id) do
      %Installation{credentials_encrypted: nil} -> nil
      %Installation{credentials_encrypted: json} -> Jason.decode!(json)
      nil -> nil
    end
  end

  @doc """
  Serialize a credentials read-modify-write for one `(provider, external_id)`
  installation against concurrent refreshers.

  Providers that rotate the refresh token on use (e.g. Bitbucket) MUST run their
  read-check-refresh-write under this guard. Two concurrent deliveries for one
  workspace would otherwise both refresh with the same refresh token; the
  provider revokes the first on the second's success, the loser's call fails, and
  a stale last-write-wins `put_credentials` can clobber the rotated token —
  permanently bricking the installation until manual re-OAuth.

  Runs `fun` inside a `Repo.transaction` holding a Postgres transaction-scoped
  advisory lock keyed on `provider` + `external_id` (`pg_advisory_xact_lock`,
  auto-released at commit/rollback). The lock is per-installation, so refreshes
  for distinct installations never block each other. `fun` should DOUBLE-CHECK
  expiry after acquiring the lock: the loser re-reads the now-fresh bundle the
  winner persisted and skips the redundant (and now-failing) refresh.

  Returns the wrapped `{:ok, term}` / `{:error, term}` from `Repo.transaction`.
  """
  @spec with_credentials_lock(String.t(), String.t(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: var
  def with_credentials_lock(provider, external_id, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
        [provider, external_id]
      )

      fun.()
    end)
  end

  ## ---- Repos ----

  @doc "List repos for an installation (by vcs_installation PK)."
  @spec repos_for_installation(integer()) :: [VcsRepo.t()]
  def repos_for_installation(installation_pk) do
    from(r in VcsRepo, where: r.installation_id == ^installation_pk) |> Repo.all()
  end

  @doc """
  Every repo across ALL providers for an org, joined to its installation's
  display identity.

  Joins `vcs_repo` → `vcs_installation` on the internal FK, filters to the org's
  ACTIVE installations (neither tombstone set), and projects the
  provider-neutral fields the unified `/repos` listing needs (the repo columns
  plus the installation's `provider` and `account_name`). Repos of
  deleted/suspended installations, and of other orgs, are excluded.
  """
  @spec list_repos_for_org(Ecto.UUID.t()) :: [
          %{
            provider: String.t(),
            account_name: String.t(),
            full_name: String.t(),
            name: String.t(),
            owner: String.t(),
            clone_url: String.t(),
            default_branch: String.t(),
            private: boolean(),
            last_synced_at: DateTime.t() | nil
          }
        ]
  def list_repos_for_org(org_id) do
    from(r in VcsRepo,
      join: i in Installation,
      on: i.id == r.installation_id,
      where: i.organization_id == ^org_id and is_nil(i.deleted_at) and is_nil(i.suspended_at),
      select: %{
        provider: r.provider,
        account_name: i.account_name,
        full_name: r.full_name,
        name: r.name,
        owner: r.owner,
        clone_url: r.clone_url,
        default_branch: r.default_branch,
        private: r.private,
        last_synced_at: r.last_synced_at
      }
    )
    |> Repo.all()
  end

  ## ---- Provider checks ----

  @spec create_provider_check(map()) ::
          {:ok, ProviderCheck.t()} | {:error, Ecto.Changeset.t()}
  def create_provider_check(attrs) do
    attrs |> ProviderCheck.create_changeset() |> Repo.insert()
  end

  @spec provider_check_by_build_uuid(String.t()) :: ProviderCheck.t() | nil
  def provider_check_by_build_uuid(build_uuid) do
    Repo.get_by(ProviderCheck, build_uuid: build_uuid)
  end

  @doc """
  Terminal-write the canonical neutral build state onto a provider check.

  This is the SINGLE place the engine records a check's terminal phase; providers
  no longer write `vcs_provider_check` themselves (they only project the neutral
  state to wire vocabulary and PATCH the remote check in their `report/3`).

  Takes a `Harmont.Apps.BuildState`-shaped neutral state (`%{phase: phase}` — a
  struct or a plain map, decoupling this core context from `harmont_apps`). The
  neutral `phase` is written to the canonical `state` column.
  """
  @spec mark_provider_check_state(ProviderCheck.t(), %{
          :phase => atom(),
          optional(:provider_data) => map()
        }) :: {:ok, ProviderCheck.t()} | {:error, Ecto.Changeset.t()}
  def mark_provider_check_state(%ProviderCheck{} = m, %{phase: _} = neutral) do
    m |> ProviderCheck.state_changeset(neutral) |> Repo.update()
  end

  @spec open_provider_checks(String.t()) :: [ProviderCheck.t()]
  def open_provider_checks(provider) do
    from(c in ProviderCheck,
      where:
        c.provider == ^provider and c.state not in ["passed", "failed", "canceled", "neutral"]
    )
    |> Repo.all()
  end

  @doc """
  Every open (non-terminal) provider check across ALL providers.

  The reporter's boot reconcile drives off THIS (the actual in-flight work in the
  DB) rather than the in-memory provider registry, so a check is reconciled even
  when its provider's Application hasn't registered yet at reporter-boot time
  (runtime-registered providers race the supervised reporter's init).
  """
  @spec open_provider_checks() :: [ProviderCheck.t()]
  def open_provider_checks do
    from(c in ProviderCheck,
      where: c.state not in ["passed", "failed", "canceled", "neutral"]
    )
    |> Repo.all()
  end
end
