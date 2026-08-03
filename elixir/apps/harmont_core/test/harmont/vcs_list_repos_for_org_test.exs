defmodule Harmont.VcsListReposForOrgTest do
  @moduledoc """
  `Harmont.Vcs.list_repos_for_org/1` returns every repo across all providers for
  an org, joined to its installation's `account_name`/`provider`, excluding repos
  whose installation is tombstoned (deleted/suspended) or bound to another org.
  """
  use Harmont.DataCase, async: true

  alias Harmont.Orgs
  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  defp create_org(slug) do
    {:ok, org} = Orgs.create_org(%{name: "Org #{slug}", slug: slug}, Repo)
    org
  end

  defp insert_installation!(attrs) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %VcsInstallation{
          account_kind: "Organization",
          created_at: now,
          updated_at: now
        },
        attrs
      )
    )
  end

  defp insert_repo!(inst, attrs) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %VcsRepo{
          installation_id: inst.id,
          provider: inst.provider,
          created_at: now,
          updated_at: now,
          last_synced_at: now
        },
        attrs
      )
    )
  end

  test "returns repos across providers with account_name + provider, scoped to the org" do
    org = create_org("acme")

    gh =
      insert_installation!(%{
        provider: "github",
        external_id: "111",
        organization_id: org.id,
        account_name: "acme-gh"
      })

    bb =
      insert_installation!(%{
        provider: "bitbucket",
        external_id: "acme-ws",
        organization_id: org.id,
        account_name: "acme-ws",
        account_kind: "workspace"
      })

    insert_repo!(gh, %{
      external_repo_id: "9001",
      full_name: "acme-gh/api",
      name: "api",
      owner: "acme-gh",
      clone_url: "https://github.com/acme-gh/api.git",
      default_branch: "main",
      private: true
    })

    insert_repo!(bb, %{
      external_repo_id: "acme-ws/web",
      full_name: "acme-ws/web",
      name: "web",
      owner: "acme-ws",
      clone_url: "https://bitbucket.org/acme-ws/web.git",
      default_branch: "develop",
      private: false
    })

    rows = Vcs.list_repos_for_org(org.id)

    assert length(rows) == 2

    by_name = Map.new(rows, &{&1.full_name, &1})

    assert by_name["acme-gh/api"].provider == "github"
    assert by_name["acme-gh/api"].account_name == "acme-gh"
    assert by_name["acme-gh/api"].default_branch == "main"
    assert by_name["acme-gh/api"].private == true

    assert by_name["acme-ws/web"].provider == "bitbucket"
    assert by_name["acme-ws/web"].account_name == "acme-ws"
  end

  test "excludes repos of tombstoned installations and other orgs" do
    org = create_org("scoped")
    other = create_org("other")

    deleted =
      insert_installation!(%{
        provider: "github",
        external_id: "222",
        organization_id: org.id,
        account_name: "gone",
        deleted_at: DateTime.utc_now()
      })

    suspended =
      insert_installation!(%{
        provider: "github",
        external_id: "333",
        organization_id: org.id,
        account_name: "paused",
        suspended_at: DateTime.utc_now()
      })

    foreign =
      insert_installation!(%{
        provider: "github",
        external_id: "444",
        organization_id: other.id,
        account_name: "theirs"
      })

    for {inst, fname} <- [{deleted, "gone/x"}, {suspended, "paused/y"}, {foreign, "theirs/z"}] do
      [owner, name] = String.split(fname, "/")

      insert_repo!(inst, %{
        external_repo_id: fname,
        full_name: fname,
        name: name,
        owner: owner,
        clone_url: "https://github.com/#{fname}.git",
        default_branch: "main",
        private: false
      })
    end

    assert Vcs.list_repos_for_org(org.id) == []
  end
end
