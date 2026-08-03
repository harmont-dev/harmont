defmodule HarmontApi.GithubTest do
  @moduledoc """
  End-to-end tests for the org-scoped GitHub integration endpoints.

  The bearer plug, the `OrgScope` tenancy plug, and the `Harmont.Github`
  context all run for real against Postgres. The `sync` action's live GitHub
  round-trip is exercised only on its 404 (tenancy) and 503 (App not booted in
  test) branches; the happy live sync is covered by `Harmont.Github`'s own
  `sync_installation_live/3` tests.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Orgs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp create_org(name, slug) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    org
  end

  defp member_org(name, slug, user) do
    org = create_org(name, slug)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)
    org
  end

  defp insert_install!(number, org_id, login) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "github",
      external_id: to_string(number),
      organization_id: org_id,
      account_name: login,
      account_kind: "Organization",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_repo!(internal_id, gh_repo_id, full_name) do
    now = DateTime.utc_now()
    [owner, name] = String.split(full_name, "/", parts: 2)

    Repo.insert!(%VcsRepo{
      installation_id: internal_id,
      provider: "github",
      external_repo_id: to_string(gh_repo_id),
      full_name: full_name,
      name: name,
      owner: owner,
      clone_url: "https://github.com/#{full_name}.git",
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
      case Keyword.get(opts, :body) do
        nil -> conn
        body -> %{conn | body_params: body, params: Map.merge(conn.params, body)}
      end

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # GET installations
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/github/installations" do
    test "lists the org's connected installations" do
      user = create_user("ghlist@harmont.dev")
      org = member_org("Acme", "gh-list", user)
      insert_install!(11, org.id, "acme")

      conn =
        req(:get, "/api/v0/organizations/gh-list/github/installations", bearer: bearer_for(user))

      assert conn.status == 200
      [inst] = decode(conn)["data"]
      assert inst["installation_id"] == 11
      assert inst["account_login"] == "acme"
      assert inst["account_type"] == "Organization"
      assert is_integer(inst["id"])
      assert is_binary(inst["created_at"])
    end

    test "non-member org -> 404" do
      user = create_user("ghout@harmont.dev")
      _org = create_org("Secret", "gh-secret")

      conn =
        req(:get, "/api/v0/organizations/gh-secret/github/installations",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      _org = create_org("Pub", "gh-pub")
      conn = req(:get, "/api/v0/organizations/gh-pub/github/installations", [])
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # POST installations (connect)
  # ---------------------------------------------------------------------------

  describe "POST /organizations/:org/github/installations" do
    test "binds an existing unbound install -> 201" do
      user = create_user("ghbind@harmont.dev")
      org = member_org("Acme", "gh-bind", user)
      insert_install!(22, nil, "acme")

      conn =
        req(:post, "/api/v0/organizations/gh-bind/github/installations",
          bearer: bearer_for(user),
          body: %{"installation_id" => 22}
        )

      assert conn.status == 201
      assert decode(conn)["installation_id"] == 22
      assert Repo.get_by(VcsInstallation, external_id: "22").organization_id == org.id
    end

    test "install bound to another org -> 409" do
      user = create_user("ghbind2@harmont.dev")
      _org = member_org("Acme", "gh-bind2", user)
      other = create_org("Other", "gh-other")
      insert_install!(23, other.id, "other")

      conn =
        req(:post, "/api/v0/organizations/gh-bind2/github/installations",
          bearer: bearer_for(user),
          body: %{"installation_id" => 23}
        )

      assert conn.status == 409
      assert decode(conn)["error"]["code"] == "github_installation_bound_elsewhere"
    end

    test "unknown install -> 404" do
      user = create_user("ghbind3@harmont.dev")
      _org = member_org("Acme", "gh-bind3", user)

      conn =
        req(:post, "/api/v0/organizations/gh-bind3/github/installations",
          bearer: bearer_for(user),
          body: %{"installation_id" => 9_999}
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "github_installation_not_found"
    end

    test "missing installation_id -> 422" do
      user = create_user("ghbind4@harmont.dev")
      _org = member_org("Acme", "gh-bind4", user)

      conn =
        req(:post, "/api/v0/organizations/gh-bind4/github/installations",
          bearer: bearer_for(user),
          body: %{}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "github_installation_id_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE installations/:id (disconnect)
  # ---------------------------------------------------------------------------

  describe "DELETE /organizations/:org/github/installations/:id" do
    test "unbinds the install -> 204" do
      user = create_user("ghdel@harmont.dev")
      org = member_org("Acme", "gh-del", user)
      insert_install!(33, org.id, "acme")

      conn =
        req(:delete, "/api/v0/organizations/gh-del/github/installations/33",
          bearer: bearer_for(user)
        )

      assert conn.status == 204
      assert is_nil(Repo.get_by(VcsInstallation, external_id: "33").organization_id)
    end

    test "non-member org -> 404" do
      user = create_user("ghdel2@harmont.dev")
      _org = create_org("Secret", "gh-del-secret")

      conn =
        req(:delete, "/api/v0/organizations/gh-del-secret/github/installations/1",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
    end

    test "non-numeric id -> 404 github_installation_not_found (not a 500)" do
      user = create_user("ghdel3@harmont.dev")
      _org = member_org("Acme", "gh-del-nan", user)

      conn =
        req(:delete, "/api/v0/organizations/gh-del-nan/github/installations/not-a-number",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "github_installation_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # GET installations/:id/repos
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/github/installations/:id/repos" do
    test "lists the install's repos, ordered by full_name" do
      user = create_user("ghrepos@harmont.dev")
      org = member_org("Acme", "gh-repos", user)
      inst = insert_install!(44, org.id, "acme")
      insert_repo!(inst.id, 1, "acme/zebra")
      insert_repo!(inst.id, 2, "acme/apple")

      conn =
        req(:get, "/api/v0/organizations/gh-repos/github/installations/44/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      data = decode(conn)["data"]
      assert Enum.map(data, & &1["full_name"]) == ["acme/apple", "acme/zebra"]
      assert hd(data)["clone_url"] == "https://github.com/acme/apple.git"
    end

    test "install bound to another org -> empty list" do
      user = create_user("ghrepos2@harmont.dev")
      _org = member_org("Acme", "gh-repos2", user)
      other = create_org("Other", "gh-repos-other")
      inst = insert_install!(45, other.id, "other")
      insert_repo!(inst.id, 1, "other/secret")

      conn =
        req(:get, "/api/v0/organizations/gh-repos2/github/installations/45/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      assert decode(conn)["data"] == []
    end

    test "non-numeric id -> 404 github_installation_not_found (not a 500)" do
      user = create_user("ghrepos3@harmont.dev")
      _org = member_org("Acme", "gh-repos-nan", user)

      conn =
        req(:get, "/api/v0/organizations/gh-repos-nan/github/installations/xyz/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "github_installation_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # POST installations/:id/sync
  # ---------------------------------------------------------------------------

  describe "POST /organizations/:org/github/installations/:id/sync" do
    test "install not connected to this org -> 404" do
      user = create_user("ghsync404@harmont.dev")
      _org = member_org("Acme", "gh-sync-404", user)

      conn =
        req(:post, "/api/v0/organizations/gh-sync-404/github/installations/77/sync",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "github_installation_not_found"
    end

    test "GitHub App not configured in test -> 503" do
      user = create_user("ghsync503@harmont.dev")
      org = member_org("Acme", "gh-sync-503", user)
      insert_install!(78, org.id, "acme")

      conn =
        req(:post, "/api/v0/organizations/gh-sync-503/github/installations/78/sync",
          bearer: bearer_for(user)
        )

      assert conn.status == 503
      assert decode(conn)["error"]["type"] == "service_unavailable"
    end

    test "non-numeric id -> 404 github_installation_not_found (not a 500)" do
      user = create_user("ghsyncnan@harmont.dev")
      _org = member_org("Acme", "gh-sync-nan", user)

      conn =
        req(:post, "/api/v0/organizations/gh-sync-nan/github/installations/nope/sync",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "github_installation_not_found"
    end
  end
end
