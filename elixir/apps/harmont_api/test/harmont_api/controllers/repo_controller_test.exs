defmodule HarmontApi.Controllers.RepoControllerTest do
  @moduledoc """
  End-to-end tests for the unified, provider-agnostic repo listing.

  The bearer plug, the `OrgScope` tenancy plug, and the `Harmont.Vcs` context all
  run for real against Postgres. Verifies cross-provider listing, canonical-URL
  grouping into a single multi-registration row, tenancy scoping, and auth.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Orgs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp member_org(slug, user) do
    {:ok, org} = Orgs.create_org(%{name: "Org #{slug}", slug: slug}, Repo)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)
    org
  end

  defp insert_installation!(provider, external_id, org_id, account) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: provider,
      external_id: external_id,
      organization_id: org_id,
      account_name: account,
      account_kind: if(provider == "bitbucket", do: "workspace", else: "Organization"),
      created_at: now,
      updated_at: now
    })
  end

  defp insert_repo!(inst, full_name, clone_url) do
    now = DateTime.utc_now()
    [owner, name] = String.split(full_name, "/", parts: 2)

    Repo.insert!(%VcsRepo{
      installation_id: inst.id,
      provider: inst.provider,
      external_repo_id: full_name,
      full_name: full_name,
      name: name,
      owner: owner,
      clone_url: clone_url,
      default_branch: "main",
      private: false,
      last_synced_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp req(method, path, opts) do
    conn =
      method
      |> Plug.Test.conn(path, "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "lists repos across providers, one row per repo" do
    user = create_user("repos@harmont.dev")
    org = member_org("acme", user)

    gh = insert_installation!("github", "111", org.id, "acme-gh")
    bb = insert_installation!("bitbucket", "acme-ws", org.id, "acme-ws")
    insert_repo!(gh, "acme-gh/api", "https://github.com/acme-gh/api.git")
    insert_repo!(bb, "acme-ws/web", "https://bitbucket.org/acme-ws/web.git")

    conn = req(:get, "/api/v0/organizations/acme/repos", bearer: bearer_for(user))

    assert conn.status == 200
    rows = decode(conn)["data"]
    assert length(rows) == 2

    by_name = Map.new(rows, &{&1["full_name"], &1})

    assert [%{"provider" => "github", "account" => "acme-gh"}] =
             by_name["acme-gh/api"]["registrations"]

    assert [%{"provider" => "bitbucket", "account" => "acme-ws"}] =
             by_name["acme-ws/web"]["registrations"]
  end

  test "merges duplicate clone URLs into one row with multiple registrations" do
    user = create_user("dup@harmont.dev")
    org = member_org("dup", user)

    # Same github.com remote reachable through two installations → one logical
    # repo with two registrations.
    a = insert_installation!("github", "201", org.id, "team-a")
    b = insert_installation!("github", "202", org.id, "team-b")
    insert_repo!(a, "shared/lib", "https://github.com/shared/lib.git")
    insert_repo!(b, "shared/lib", "https://github.com/shared/lib")

    conn = req(:get, "/api/v0/organizations/dup/repos", bearer: bearer_for(user))

    assert conn.status == 200
    rows = decode(conn)["data"]
    assert length(rows) == 1

    accounts =
      rows |> hd() |> Map.fetch!("registrations") |> Enum.map(& &1["account"]) |> Enum.sort()

    assert accounts == ["team-a", "team-b"]
  end

  test "non-member org -> 404" do
    user = create_user("out@harmont.dev")
    {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "secret"}, Repo)

    conn = req(:get, "/api/v0/organizations/secret/repos", bearer: bearer_for(user))
    assert conn.status == 404
    assert decode(conn)["error"]["code"] == "organization_not_found"
  end

  test "unauthed -> 401" do
    conn = req(:get, "/api/v0/organizations/acme/repos", [])
    assert conn.status == 401
  end
end
