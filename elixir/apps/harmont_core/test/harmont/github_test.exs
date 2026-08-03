defmodule Harmont.GithubTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Github
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_org!(slug \\ "acme") do
    {:ok, org} =
      Repo.insert(Organization.changeset(%Organization{}, %{name: "Acme", slug: slug}))

    org
  end

  # Insert a vcs_installation row (provider "github") directly. organization_id
  # binds it to an org (or nil for an unbound install). `installation_number` is
  # the GitHub integer, stored as the `external_id` STRING. Returns the row.
  defp insert_installation!(installation_number, organization_id) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "github",
      external_id: to_string(installation_number),
      organization_id: organization_id,
      account_name: "acme",
      account_kind: "Organization",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_repo!(internal_installation_id, gh_repo_id, full_name) do
    now = DateTime.utc_now()
    [_, name] = String.split(full_name, "/", parts: 2)

    Repo.insert!(%VcsRepo{
      installation_id: internal_installation_id,
      provider: "github",
      external_repo_id: to_string(gh_repo_id),
      full_name: full_name,
      name: name,
      owner: "acme",
      clone_url: "https://github.com/#{full_name}.git",
      default_branch: "main",
      private: false,
      last_synced_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp repo_map(gh_repo_id, full_name, overrides \\ %{}) do
    [_, name] = String.split(full_name, "/", parts: 2)

    Map.merge(
      %{
        gh_repo_id: gh_repo_id,
        full_name: full_name,
        name: name,
        owner: "acme",
        clone_url: "https://github.com/#{full_name}.git",
        default_branch: "main",
        private: false
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # sync_installation/4
  # ---------------------------------------------------------------------------

  describe "sync_installation/4 (bound org)" do
    setup do
      org = insert_org!()
      inst = insert_installation!(42, org.id)
      # Existing rows: "keep" survives+updates, "drop" vanishes.
      insert_repo!(inst.id, 1, "acme/keep")
      insert_repo!(inst.id, 2, "acme/drop")
      %{org: org, inst: inst}
    end

    test "deletes vanished and upserts present repos; creates no pipelines", %{inst: inst} do
      now = DateTime.utc_now()

      fetched = [
        # update existing repo 1: rename + flip private + new default branch
        repo_map(1, "acme/keep-renamed", %{private: true, default_branch: "trunk"}),
        # brand-new repo 3
        repo_map(3, "acme/added")
      ]

      assert {:ok, counts} = Github.sync_installation(inst.id, fetched, now, Repo)
      assert counts == %{upserted: 2, deleted: 1}

      # repo 2 ("drop") is gone.
      assert is_nil(Repo.get_by(VcsRepo, external_repo_id: "2"))

      # repo 1 updated in place.
      r1 = Repo.get_by(VcsRepo, external_repo_id: "1")
      assert r1.full_name == "acme/keep-renamed"
      assert r1.private == true
      assert r1.default_branch == "trunk"
      assert DateTime.compare(r1.last_synced_at, now) == :eq

      # repo 3 inserted.
      r3 = Repo.get_by(VcsRepo, external_repo_id: "3")
      assert r3.full_name == "acme/added"
      assert r3.installation_id == inst.id

      # No pipeline rows created — discovery is enqueued separately.
      assert Repo.aggregate(Pipeline, :count) == 0
    end

    test "is idempotent across multiple syncs", %{inst: inst} do
      fetched = [repo_map(1, "acme/keep"), repo_map(3, "acme/added")]

      assert {:ok, _} = Github.sync_installation(inst.id, fetched, DateTime.utc_now(), Repo)

      assert {:ok, counts} =
               Github.sync_installation(inst.id, fetched, DateTime.utc_now(), Repo)

      assert counts == %{upserted: 2, deleted: 0}
      assert Repo.aggregate(Pipeline, :count) == 0
    end
  end

  describe "sync_installation/4 (unbound installation)" do
    test "upserts repos and creates no pipelines" do
      inst = insert_installation!(99, nil)
      insert_repo!(inst.id, 1, "acme/keep")

      fetched = [repo_map(1, "acme/keep"), repo_map(3, "acme/added")]

      assert {:ok, counts} = Github.sync_installation(inst.id, fetched, DateTime.utc_now(), Repo)
      assert counts == %{upserted: 2, deleted: 0}
      assert Repo.aggregate(Pipeline, :count) == 0
      assert Repo.get_by(VcsRepo, external_repo_id: "3")
    end
  end

  describe "sync_installation/4 (unknown installation)" do
    test "is a no-op" do
      assert {:ok, %{upserted: 0, deleted: 0}} =
               Github.sync_installation(
                 123_456_789,
                 [repo_map(1, "acme/x")],
                 DateTime.utc_now(),
                 Repo
               )
    end
  end

  # ---------------------------------------------------------------------------
  # sync_installation/4 — concurrent-insert / snapshot-miss collision
  # ---------------------------------------------------------------------------

  describe "sync_installation/4 (snapshot-miss collision)" do
    # Regression for the production 500 on GitHub connect (trace
    # f66d32b3…): a brand-new install is synced concurrently by the connect
    # path and the installation webhook. Both read an empty existing-rows
    # snapshot, then both insert the same (installation_id, external_repo_id),
    # and the second insert collided on unique_vcs_repo_installation_external.
    #
    # We reproduce the snapshot-miss insert path deterministically in one
    # process by listing the same gh_repo_id twice: the snapshot is computed
    # once (absent), so both list entries take the insert branch and the
    # second collides — the exact code path the concurrent webhook hits.
    test "converges instead of raising when a repo id is seen after the snapshot" do
      org = insert_org!()
      inst = insert_installation!(42, org.id)

      fetched = [
        repo_map(7, "acme/first"),
        repo_map(7, "acme/second", %{private: true, default_branch: "trunk"})
      ]

      assert {:ok, _counts} =
               Github.sync_installation(inst.id, fetched, DateTime.utc_now(), Repo)

      # Exactly one row for repo 7 — the upsert collapsed the duplicate.
      assert Repo.aggregate(
               from(r in VcsRepo, where: r.external_repo_id == "7"),
               :count
             ) == 1

      # Last write wins (the second list entry).
      row = Repo.get_by(VcsRepo, external_repo_id: "7")
      assert row.full_name == "acme/second"
      assert row.private == true
      assert row.default_branch == "trunk"
      assert row.installation_id == inst.id
    end
  end

  # ---------------------------------------------------------------------------
  # list_installations_for_org/2
  # ---------------------------------------------------------------------------

  describe "list_installations_for_org/2" do
    test "returns only this org's non-deleted installs, ordered by account_login" do
      org = insert_org!("acme-list")
      other = insert_org!("other-list")

      i_b = insert_installation_named!(1, org.id, "bravo")
      i_a = insert_installation_named!(2, org.id, "alpha")
      _other_org = insert_installation_named!(3, other.id, "charlie")
      _unbound = insert_installation_named!(4, nil, "delta")
      _deleted = insert_deleted_installation!(5, org.id, "echo")

      result = Github.list_installations_for_org(org.id, Repo)
      assert Enum.map(result, & &1.account_name) == ["alpha", "bravo"]
      assert Enum.map(result, & &1.id) == [i_a.id, i_b.id]
    end

    test "returns [] for an org with no installs" do
      org = insert_org!("empty-list")
      assert Github.list_installations_for_org(org.id, Repo) == []
    end
  end

  # ---------------------------------------------------------------------------
  # bind_installation/3
  # ---------------------------------------------------------------------------

  describe "bind_installation/3" do
    test "binds an unbound mirror row to the org" do
      org = insert_org!("acme-bind")
      _inst = insert_installation!(700, nil)

      assert {:ok, bound} = Github.bind_installation(700, org.id, Repo)
      assert bound.organization_id == org.id
      assert Repo.get_by(VcsInstallation, external_id: "700").organization_id == org.id
    end

    test "is idempotent when already bound to the same org" do
      org = insert_org!("acme-bind2")
      _inst = insert_installation!(701, org.id)

      assert {:ok, bound} = Github.bind_installation(701, org.id, Repo)
      assert bound.organization_id == org.id
    end

    test "returns {:error, :already_bound} when bound to a different org" do
      org_a = insert_org!("acme-a")
      org_b = insert_org!("acme-b")
      _inst = insert_installation!(702, org_a.id)

      assert {:error, :already_bound} = Github.bind_installation(702, org_b.id, Repo)
      # unchanged
      assert Repo.get_by(VcsInstallation, external_id: "702").organization_id == org_a.id
    end

    test "returns {:error, :not_found} when no mirror row exists" do
      org = insert_org!("acme-bind3")
      assert {:error, :not_found} = Github.bind_installation(999_999, org.id, Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # unbind_installation/3
  # ---------------------------------------------------------------------------

  describe "unbind_installation/3" do
    test "clears organization_id for an install bound to this org" do
      org = insert_org!("acme-unbind")
      _inst = insert_installation!(800, org.id)

      assert :ok = Github.unbind_installation(800, org.id, Repo)
      assert is_nil(Repo.get_by(VcsInstallation, external_id: "800").organization_id)
    end

    test "is a no-op for an install bound to a different org" do
      org_a = insert_org!("acme-unbind-a")
      org_b = insert_org!("acme-unbind-b")
      _inst = insert_installation!(801, org_a.id)

      assert :ok = Github.unbind_installation(801, org_b.id, Repo)
      # still bound to A
      assert Repo.get_by(VcsInstallation, external_id: "801").organization_id == org_a.id
    end

    test "is a no-op for an unknown install" do
      org = insert_org!("acme-unbind-x")
      assert :ok = Github.unbind_installation(123, org.id, Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # list_repos_for_installation/3 + list_repos_for_org/2
  # ---------------------------------------------------------------------------

  describe "repo listings" do
    setup do
      org = insert_org!("acme-repos")
      other = insert_org!("other-repos")

      inst1 = insert_installation!(900, org.id)
      inst2 = insert_installation!(901, org.id)
      inst_other = insert_installation!(902, other.id)

      insert_repo!(inst1.id, 1, "acme/zebra")
      insert_repo!(inst1.id, 2, "acme/apple")
      insert_repo!(inst2.id, 3, "acme/mango")
      insert_repo!(inst_other.id, 4, "other/secret")

      %{org: org, other: other}
    end

    test "list_repos_for_installation scopes to the org's installation, ordered by full_name",
         %{org: org} do
      result = Github.list_repos_for_installation(org.id, 900, Repo)
      assert Enum.map(result, & &1.full_name) == ["acme/apple", "acme/zebra"]
    end

    test "list_repos_for_installation returns [] for an install bound to another org", %{
      org: org
    } do
      assert Github.list_repos_for_installation(org.id, 902, Repo) == []
    end

    test "list_repos_for_org returns every repo across the org's installs, ordered", %{org: org} do
      result = Github.list_repos_for_org(org.id, Repo)
      assert Enum.map(result, & &1.full_name) == ["acme/apple", "acme/mango", "acme/zebra"]
    end
  end

  # ---------------------------------------------------------------------------
  # Extra helpers for the org-scoped queries
  # ---------------------------------------------------------------------------

  defp insert_installation_named!(installation_number, organization_id, account_login) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "github",
      external_id: to_string(installation_number),
      organization_id: organization_id,
      account_name: account_login,
      account_kind: "Organization",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_deleted_installation!(installation_number, organization_id, account_login) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "github",
      external_id: to_string(installation_number),
      organization_id: organization_id,
      account_name: account_login,
      account_kind: "Organization",
      deleted_at: now,
      created_at: now,
      updated_at: now
    })
  end
end
