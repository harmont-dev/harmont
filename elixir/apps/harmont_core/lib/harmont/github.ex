defmodule Harmont.Github do
  @moduledoc """
  Context for the GitHub-mirror domain: reconciling an installation's
  repositories into the provider-agnostic `vcs_repo` table.

  All install/repo storage now lives on the unified `vcs_installation` /
  `vcs_repo` tables (provider `"github"`) via `Harmont.Vcs`; this module
  queries/writes those and returns `%Harmont.Vcs.Installation{}` /
  `%Harmont.Vcs.Repo{}` structs.

  Pipeline creation is handled by `Harmont.GhApp.Webhook.DiscoverPipelines`,
  which is enqueued after each successful sync. `sync_installation/4` no longer
  creates placeholder pipelines.

  ## Installation id vs. number

  `vcs_repo.installation_id` is a foreign key onto `vcs_installation.id`
  — the internal bigserial primary key — **not** the numeric GitHub
  installation id (which is stored as a STRING in `vcs_installation.external_id`).
  `sync_installation/4` takes that **internal** id directly so the existing-rows
  query is a plain equality on the FK. The webhook handler receives the GitHub
  installation **number**; `sync_installation_live/3` resolves it to the internal
  row first.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Orgs.Slug
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @provider "github"

  @type repo_map :: %{
          gh_repo_id: integer(),
          full_name: String.t(),
          name: String.t(),
          owner: String.t(),
          clone_url: String.t(),
          default_branch: String.t(),
          private: boolean()
        }

  @doc """
  Reconcile the fetched repo list against the `vcs_repo` rows for one
  installation, identified by its **internal** `vcs_installation.id`.

  Port of `applyRepoSync` (repo-mirror step only):

    * load existing `vcs_repo` rows for the installation,
    * hard-delete rows whose `external_repo_id` is no longer in `fetched_repos`,
    * upsert every fetched repo (update mutable fields, or insert).

  Pipeline creation is no longer performed here — it is delegated to
  `Harmont.GhApp.Webhook.DiscoverPipelines`, enqueued by the caller after a
  successful sync.

  Returns `{:ok, %{upserted: n, deleted: n}}`. When the installation row does
  not exist, returns `{:ok, %{upserted: 0, deleted: 0}}`.

  Runs inside a single `repo.transaction/1` so a partial sync never lands.
  """
  @spec sync_installation(integer(), [repo_map()], DateTime.t(), module()) ::
          {:ok,
           %{
             upserted: non_neg_integer(),
             deleted: non_neg_integer()
           }}
  def sync_installation(internal_installation_id, fetched_repos, now, repo) do
    case repo.get(VcsInstallation, internal_installation_id) do
      nil ->
        {:ok, %{upserted: 0, deleted: 0}}

      %VcsInstallation{} = _inst ->
        repo.transaction(fn ->
          reconcile(internal_installation_id, fetched_repos, now, repo)
        end)
    end
  end

  # Body of the sync transaction: delete vanished rows, upsert present ones.
  # Returns the counts map. Pipeline creation is delegated to DiscoverPipelines.
  defp reconcile(internal_installation_id, fetched_repos, now, repo) do
    existing = existing_repos(internal_installation_id, repo)
    existing_by_ext_id = Map.new(existing, &{&1.external_repo_id, &1})
    fetched_by_ext_id = Map.new(fetched_repos, &{to_string(&1.gh_repo_id), &1})

    deleted = delete_vanished(existing_by_ext_id, fetched_by_ext_id, repo)

    Enum.each(
      fetched_repos,
      &upsert_repo(internal_installation_id, &1, now, repo)
    )

    %{upserted: length(fetched_repos), deleted: deleted}
  end

  @doc """
  Live variant: mint/use the installation token (the caller supplies an already
  authed `%GithubClient{}`), list the installation's repos via the GitHub API,
  then `sync_installation/4`.

  `github_installation_number` is the **GitHub** installation id; it is
  resolved to the internal `vcs_installation` row here. `github_client` must
  carry the installation access token. Returns the sync counts, or
  `{:error, term}` if the listing fails or the installation is unknown.
  """
  @spec sync_installation_live(integer(), GithubClient.t(), module()) ::
          {:ok, map()} | {:error, term()}
  def sync_installation_live(github_installation_number, github_client, repo) do
    case repo.get_by(VcsInstallation,
           provider: @provider,
           external_id: to_string(github_installation_number)
         ) do
      nil ->
        {:error, :installation_not_found}

      %VcsInstallation{id: internal_id} ->
        with {:ok, fetched} <-
               GithubClient.list_installation_repos(github_client, github_installation_number) do
          sync_installation(internal_id, fetched, DateTime.utc_now(), repo)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Org-scoped queries + installation binding (harmont-api edge)
  # ---------------------------------------------------------------------------

  @doc """
  List the `vcs_installation` rows (provider "github") bound to `org_id` that
  are not tombstoned (`deleted_at IS NULL`), ordered by `account_name`.

  Tombstoned installs (`installation.deleted` webhook) are excluded so the
  connect UI never shows installs that no longer exist on GitHub.
  """
  @spec list_installations_for_org(Ecto.UUID.t(), module()) :: [VcsInstallation.t()]
  def list_installations_for_org(org_id, repo) do
    repo.all(
      from(i in VcsInstallation,
        where: i.provider == @provider and i.organization_id == ^org_id and is_nil(i.deleted_at),
        order_by: i.account_name
      )
    )
  end

  @doc """
  Look up a `vcs_installation` row (provider "github") by its **GitHub**
  installation number, or `nil` if absent. Tombstoned rows are included; the
  caller decides what to do with a soft-deleted install.
  """
  @spec get_installation_by_number(integer(), module()) :: VcsInstallation.t() | nil
  def get_installation_by_number(number, _repo) do
    Harmont.Vcs.get_installation(@provider, to_string(number))
  end

  @doc """
  Bind the GitHub installation identified by `number` to `org_id`.

  ## Bind requires an existing mirror row

  Rather than asking GitHub (via the App's `listInstallations`) whether the
  installation exists and then upserting the row, we require the
  `vcs_installation` **row to already exist in
  our mirror** — it is written by this app's `installation.created` webhook
  handler (`Harmont.GhApp.Store.upsert_installation/1`) the moment a user
  installs the App. This removes the live App-JWT round-trip from the bind
  path: by the time the SPA POSTs here (right after the GitHub install
  redirect) the webhook row is present, and an absent row means the install
  genuinely is not ours. A bind for an unknown number returns
  `{:error, :not_found}`.

  Returns:

    * `{:ok, inst}` — newly bound, or already bound to this same org (idempotent),
    * `{:error, :already_bound}` — bound to a *different* org (409 at the edge),
    * `{:error, :not_found}` — no mirror row for this installation number.

  This performs **no per-user IDOR check** on the
  GitHub installation: it trusts that the SPA's GitHub OAuth already vetted the
  user's access to the org/installation before calling. The OrgScope plug still
  enforces that the caller is a member of the target org.
  """
  @spec bind_installation(integer(), Ecto.UUID.t(), module()) ::
          {:ok, VcsInstallation.t()} | {:error, :already_bound | :not_found}
  def bind_installation(number, org_id, repo) do
    case repo.get_by(VcsInstallation, provider: @provider, external_id: to_string(number)) do
      nil ->
        {:error, :not_found}

      %VcsInstallation{organization_id: bound}
      when bound != nil and bound != org_id ->
        {:error, :already_bound}

      %VcsInstallation{} = inst ->
        inst
        |> Ecto.Changeset.change(%{organization_id: org_id, updated_at: DateTime.utc_now()})
        |> repo.update()
    end
  end

  @doc """
  Unbind the installation identified by `number` from `org_id`: clears
  `organization_id` back to `nil`. Only an install currently bound to `org_id`
  is touched (a no-op otherwise, so a member of org A cannot unbind org B's
  install). Returns `:ok` regardless (idempotent unbind).
  """
  @spec unbind_installation(integer(), Ecto.UUID.t(), module()) :: :ok
  def unbind_installation(number, org_id, repo) do
    now = DateTime.utc_now()

    repo.update_all(
      from(i in VcsInstallation,
        where:
          i.provider == @provider and i.external_id == ^to_string(number) and
            i.organization_id == ^org_id
      ),
      set: [organization_id: nil, updated_at: now]
    )

    :ok
  end

  @doc """
  List the mirrored `vcs_repo` rows for the installation identified by
  GitHub `number`, **scoped to `org_id`**: repos are only returned when the
  installation is bound to `org_id`. Returns `[]` for an unknown installation
  or one bound to another org (tenancy). Ordered by `full_name`.
  """
  @spec list_repos_for_installation(Ecto.UUID.t(), integer(), module()) :: [VcsRepo.t()]
  def list_repos_for_installation(org_id, number, repo) do
    repo.all(
      from(r in VcsRepo,
        join: i in VcsInstallation,
        on: i.id == r.installation_id,
        where:
          i.provider == @provider and i.external_id == ^to_string(number) and
            i.organization_id == ^org_id,
        order_by: r.full_name
      )
    )
  end

  @doc """
  List every mirrored `vcs_repo` across all installations bound to
  `org_id`, ordered by `full_name`.
  """
  @spec list_repos_for_org(Ecto.UUID.t(), module()) :: [VcsRepo.t()]
  def list_repos_for_org(org_id, repo) do
    repo.all(
      from(r in VcsRepo,
        join: i in VcsInstallation,
        on: i.id == r.installation_id,
        where: i.provider == @provider and i.organization_id == ^org_id,
        order_by: r.full_name
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Private — repo reconciliation
  # ---------------------------------------------------------------------------

  defp existing_repos(internal_installation_id, repo) do
    repo.all(from(r in VcsRepo, where: r.installation_id == ^internal_installation_id))
  end

  defp delete_vanished(existing_by_ext_id, fetched_by_ext_id, repo) do
    existing_by_ext_id
    |> Enum.reject(fn {ext_id, _row} -> Map.has_key?(fetched_by_ext_id, ext_id) end)
    |> Enum.map(fn {_ext_id, row} -> repo.delete!(row) end)
    |> length()
  end

  # Atomic upsert keyed on the (installation_id, external_repo_id) unique index.
  # Using INSERT ... ON CONFLICT DO UPDATE (rather than a check-then-insert
  # against a pre-read snapshot) makes concurrent syncs converge instead of one
  # of them raising Ecto.ConstraintError: the connect path's synchronous
  # sync_on_connect and the installation webhook's SyncRepos Oban job both
  # reconcile a brand-new install at the same moment, and the loser used to
  # collide on unique_vcs_repo_installation_external. The DB resolves the
  # collision here, so neither writer fails. (Bug: GitHub connect 500, trace
  # f66d32b3, github.ex:92.)
  defp upsert_repo(internal_installation_id, r, now, repo) do
    repo.insert!(
      %VcsRepo{
        installation_id: internal_installation_id,
        provider: @provider,
        external_repo_id: to_string(r.gh_repo_id),
        full_name: r.full_name,
        name: r.name,
        owner: r.owner,
        clone_url: r.clone_url,
        default_branch: r.default_branch,
        private: r.private,
        last_synced_at: now,
        created_at: now,
        updated_at: now
      },
      on_conflict:
        {:replace,
         [
           :full_name,
           :name,
           :owner,
           :clone_url,
           :default_branch,
           :private,
           :last_synced_at,
           :updated_at
         ]},
      conflict_target: [:installation_id, :external_repo_id]
    )
  end

  @doc """
  Reconcile the pipelines for one repo against its discovered registry.

  `repo_info` is a map with `:full_name`, `:clone_url`, `:default_branch`.
  `discovered` is the list from `Harmont.Pipelines.Discovery.parse_envelope/1`.
  Upserts one `pipelines` row per discovered pipeline (keyed on
  `(organization_id, repository=clone_url, source_slug)`) and archives repo
  pipelines no longer present. Runs in a transaction. Returns
  `{:ok, %{created: n, archived: n}}`.
  """
  @spec reconcile_discovered(binary(), map(), [map()], DateTime.t(), module()) ::
          {:ok, %{created: non_neg_integer(), archived: non_neg_integer()}}
  def reconcile_discovered(organization_id, repo_info, discovered, now, repo) do
    repo.transaction(fn ->
      adopt_placeholder(organization_id, repo_info, discovered, now, repo)

      created =
        Enum.count(discovered, &upsert_discovered(organization_id, repo_info, &1, now, repo))

      archived = archive_absent(organization_id, repo_info, discovered, now, repo)
      %{created: created, archived: archived}
    end)
  end

  # A repo can already carry a manually-created pipeline — made via "New Pipeline"
  # on the repo card — anchored to its `repository` with `source_slug: nil`.
  # Discovery keys identity on `(organization_id, repository, source_slug)`, so
  # without this step it misses that row and INSERTs a parallel pipeline. The repo
  # then has two pipelines for one `.hm` file: the manual one (no triggers,
  # so webhooks never match it — it shows zero builds in the UI) and the
  # discovered one (where builds actually land). To prevent the fork, when
  # discovery yields exactly one pipeline and the repo has exactly one such
  # placeholder, stamp the discovered `source_slug` onto the placeholder so
  # `upsert_discovered` updates it in place. Ambiguous cases (several discovered
  # pipelines, or several placeholders) are left untouched — we never guess which
  # manual pipeline maps to which discovered one.
  defp adopt_placeholder(org_id, repo_info, [%{source_slug: source_slug}], now, repo) do
    already_discovered? =
      repo.get_by(Pipeline,
        organization_id: org_id,
        repository: repo_info.clone_url,
        source_slug: source_slug
      ) != nil

    placeholders =
      repo.all(
        from(p in Pipeline,
          where:
            p.organization_id == ^org_id and p.repository == ^repo_info.clone_url and
              is_nil(p.source_slug) and p.archived == false
        )
      )

    case {already_discovered?, placeholders} do
      {false, [placeholder]} ->
        placeholder
        |> Ecto.Changeset.change(%{
          source_slug: source_slug,
          repo_name: repo_info.full_name,
          github_repo_id: Map.get(repo_info, :github_repo_id),
          updated_at: now
        })
        |> repo.update!()

      _ ->
        :ok
    end
  end

  defp adopt_placeholder(_org_id, _repo_info, _discovered, _now, _repo), do: :ok

  # true if a NEW pipeline row was inserted (false if it already existed + was updated).
  defp upsert_discovered(organization_id, repo_info, d, now, repo) do
    slug = "#{Slug.normalize(repo_info.full_name)}-#{Slug.normalize(d.source_slug)}"

    case repo.get_by(Pipeline,
           organization_id: organization_id,
           repository: repo_info.clone_url,
           source_slug: d.source_slug
         ) do
      nil ->
        repo.insert!(%Pipeline{
          organization_id: organization_id,
          name: d.name,
          slug: slug,
          source_slug: d.source_slug,
          repository: repo_info.clone_url,
          repo_name: repo_info.full_name,
          github_repo_id: Map.get(repo_info, :github_repo_id),
          default_branch: repo_info.default_branch,
          triggers: d.triggers,
          allow_manual: d.allow_manual,
          visibility: :private,
          archived: false,
          build_count: 0,
          inserted_at: now,
          updated_at: now
        })

        true

      %Pipeline{} = existing ->
        existing
        |> Ecto.Changeset.change(%{
          name: d.name,
          slug: slug,
          repo_name: repo_info.full_name,
          github_repo_id: Map.get(repo_info, :github_repo_id),
          default_branch: repo_info.default_branch,
          triggers: d.triggers,
          allow_manual: d.allow_manual,
          archived: false,
          updated_at: now
        })
        |> repo.update!()

        false
    end
  end

  defp archive_absent(organization_id, repo_info, discovered, now, repo) do
    keep = Enum.map(discovered, & &1.source_slug)

    from(p in Pipeline,
      where:
        p.organization_id == ^organization_id and
          p.repository == ^repo_info.clone_url and
          not is_nil(p.source_slug) and
          p.source_slug not in ^keep and
          p.archived == false
    )
    |> repo.update_all(set: [archived: true, updated_at: now])
    |> elem(0)
  end
end
