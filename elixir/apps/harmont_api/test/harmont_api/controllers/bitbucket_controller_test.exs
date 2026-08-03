defmodule HarmontApi.Controllers.BitbucketControllerTest do
  @moduledoc """
  End-to-end tests for the Bitbucket onboarding endpoints.

  The bearer plug, the `OrgScope` tenancy plug, and the `Harmont.Vcs` context
  all run for real against Postgres. The `connect` action's live OAuth
  round-trip is covered by `Harmont.Bitbucket.Onboarding`'s own tests; here we
  exercise the read/disconnect actions, the `oauth-url` not-configured branch,
  and `connect`'s state/membership gate (the org rides in the signed state, so
  `connect` is NOT org-scoped — it recovers the org server-side).
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Bitbucket.Runtime, as: BitbucketRuntime
  alias Harmont.Bitbucket.Settings, as: BitbucketSettings
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

  defp insert_workspace!(slug, org_id, login) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "bitbucket",
      external_id: slug,
      organization_id: org_id,
      account_name: login,
      account_kind: "workspace",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_repo!(inst, full_name) do
    now = DateTime.utc_now()
    [owner, name] = String.split(full_name, "/", parts: 2)

    Repo.insert!(%VcsRepo{
      installation_id: inst.id,
      provider: "bitbucket",
      external_repo_id: full_name,
      full_name: full_name,
      name: name,
      owner: owner,
      clone_url: "https://bitbucket.org/#{full_name}.git",
      default_branch: "main",
      private: true,
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

  # Mirror the controller's HMAC base: the endpoint secret_key_base from config.
  defp state_secret,
    do: Application.fetch_env!(:harmont_web, HarmontWeb.Endpoint)[:secret_key_base]

  # Sign a state the same way `oauth_url` does: a map carrying the user id and
  # the org slug.
  defp sign_state(user_id, org_slug),
    do:
      Phoenix.Token.sign(state_secret(), "bitbucket_oauth", %{
        "u" => user_id,
        "org" => org_slug
      })

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/oauth-url
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/bitbucket/oauth-url" do
    test "Bitbucket not configured in test -> 503" do
      user = create_user("bboauth@harmont.dev")
      _org = member_org("Acme", "bb-oauth", user)

      conn =
        req(:get, "/api/v0/organizations/bb-oauth/bitbucket/oauth-url", bearer: bearer_for(user))

      assert conn.status == 503
      assert decode(conn)["error"]["code"] == "bitbucket_not_configured"
    end

    test "non-member org -> 404" do
      user = create_user("bboauth-out@harmont.dev")
      _org = create_org("Secret", "bb-oauth-secret")

      conn =
        req(:get, "/api/v0/organizations/bb-oauth-secret/bitbucket/oauth-url",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn = req(:get, "/api/v0/organizations/bb-oauth/bitbucket/oauth-url", [])
      assert conn.status == 401
    end
  end

  describe "GET /organizations/:org/bitbucket/oauth-url (state baked into URL)" do
    setup do
      # The oauth-url action 503s unless Bitbucket settings are loaded into the
      # persistent_term holder. Load minimal settings for this block, then drop
      # them so the not-configured test in the other block still 503s.
      prev = :persistent_term.get({BitbucketRuntime, :settings}, nil)

      BitbucketRuntime.put_settings(%BitbucketSettings{
        client_id: "cid",
        client_secret: "sec",
        webhook_secret: "wh",
        oauth_base_url: "https://bitbucket.org"
      })

      on_exit(fn ->
        if prev,
          do: :persistent_term.put({BitbucketRuntime, :settings}, prev),
          else: :persistent_term.erase({BitbucketRuntime, :settings})
      end)

      :ok
    end

    test "the authorize URL contains a state nonce" do
      user = create_user("bbstate@harmont.dev")
      _org = member_org("Acme", "bb-state", user)

      conn =
        req(:get, "/api/v0/organizations/bb-state/bitbucket/oauth-url", bearer: bearer_for(user))

      assert conn.status == 200
      assert decode(conn)["url"] =~ "state="
    end
  end

  # ---------------------------------------------------------------------------
  # POST /integrations/bitbucket/connect — state + membership gate
  # ---------------------------------------------------------------------------

  describe "POST /integrations/bitbucket/connect (state verification)" do
    # A full successful connect can't run here (no live OAuth settings in test),
    # but the state + membership gate runs BEFORE the OAuth round-trip, so we
    # assert the 403 envelope on bad/missing/foreign/non-member state, and that
    # a valid state for a member org passes the gate (the request then fails
    # downstream, never with a 403).
    setup do
      user = create_user("bbconn@harmont.dev")
      org = member_org("Acme", "bb-conn", user)

      # Load settings pointing at an unroutable OAuth base so that, once a
      # request passes the gate, the downstream code exchange fails fast
      # (connection refused) and the controller returns 502 — never a 403. This
      # lets the "valid state" test assert the gate was passed without a live
      # Bitbucket. The bad/missing-state tests never reach the exchange.
      prev = :persistent_term.get({BitbucketRuntime, :settings}, nil)

      BitbucketRuntime.put_settings(%BitbucketSettings{
        client_id: "cid",
        client_secret: "sec",
        webhook_secret: "wh",
        oauth_base_url: "http://127.0.0.1:1"
      })

      on_exit(fn ->
        if prev,
          do: :persistent_term.put({BitbucketRuntime, :settings}, prev),
          else: :persistent_term.erase({BitbucketRuntime, :settings})
      end)

      %{user: user, org: org}
    end

    @parser_opts Plug.Parsers.init(
                   parsers: [:json],
                   pass: ["application/json"],
                   json_decoder: Jason
                 )

    defp post_connect(bearer, body) do
      # The JSON body parser lives in the endpoint, not the router; replicate it
      # here since these tests call the router directly.
      :post
      |> Plug.Test.conn("/api/v0/integrations/bitbucket/connect", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer)
      |> Plug.Parsers.call(@parser_opts)
      |> HarmontApi.Router.call(HarmontApi.Router.init([]))
    end

    test "missing state -> 403 bitbucket_invalid_state", %{user: user} do
      conn = post_connect(bearer_for(user), Jason.encode!(%{code: "abc123"}))

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "bitbucket_invalid_state"
    end

    test "garbage state -> 403 bitbucket_invalid_state", %{user: user} do
      conn =
        post_connect(
          bearer_for(user),
          Jason.encode!(%{code: "abc123", state: "not-a-real-token"})
        )

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "bitbucket_invalid_state"
    end

    test "state signed for another user -> 403", %{user: user, org: org} do
      other = create_user("bbconn-other@harmont.dev")
      state = sign_state(other.id, org.slug)

      conn =
        post_connect(
          bearer_for(user),
          Jason.encode!(%{code: "abc123", state: state})
        )

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "bitbucket_invalid_state"
    end

    test "state for an org the user is not a member of -> 403", %{user: user} do
      # A correctly-signed state whose org the user does not belong to must not
      # leak — `fetch_org_scoped` returns not-found, which collapses to the same
      # 403 invalid_state envelope.
      _other = create_org("Other", "bb-conn-other")
      state = sign_state(user.id, "bb-conn-other")

      conn =
        post_connect(
          bearer_for(user),
          Jason.encode!(%{code: "abc123", state: state})
        )

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "bitbucket_invalid_state"
    end

    test "valid state for a member org passes the gate (no 403)", %{user: user, org: org} do
      state = sign_state(user.id, org.slug)

      conn =
        post_connect(
          bearer_for(user),
          Jason.encode!(%{code: "abc123", state: state})
        )

      # Past the state + membership gate: must NOT be the invalid_state 403. With
      # no live OAuth settings the exchange fails downstream, proving the gate
      # was passed.
      refute conn.status == 403
      refute decode(conn)["error"]["code"] == "bitbucket_invalid_state"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /integrations/bitbucket/connect — cross-tenant takeover guard
  # ---------------------------------------------------------------------------

  describe "POST /integrations/bitbucket/connect (takeover guard)" do
    # Drive the full controller path (past the state gate, through the OAuth
    # exchange) by injecting stub exchange/workspaces funs via application env,
    # so we can assert the 409 takeover guard and that org A keeps its binding.
    setup do
      user = create_user("bbtakeover@harmont.dev")
      org = member_org("Acme B", "bb-takeover", user)

      prev_settings = :persistent_term.get({BitbucketRuntime, :settings}, nil)

      BitbucketRuntime.put_settings(%BitbucketSettings{
        client_id: "cid",
        client_secret: "sec",
        webhook_secret: "wh",
        oauth_base_url: "https://bitbucket.org"
      })

      on_exit(fn ->
        if prev_settings,
          do: :persistent_term.put({BitbucketRuntime, :settings}, prev_settings),
          else: :persistent_term.erase({BitbucketRuntime, :settings})

        Application.delete_env(:harmont_api, :bitbucket_connect_opts)
      end)

      %{user: user, org: org}
    end

    @parser_opts Plug.Parsers.init(
                   parsers: [:json],
                   pass: ["application/json"],
                   json_decoder: Jason
                 )

    defp post_connect_full(bearer, body) do
      :post
      |> Plug.Test.conn("/api/v0/integrations/bitbucket/connect", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer)
      |> Plug.Parsers.call(@parser_opts)
      |> HarmontApi.Router.call(HarmontApi.Router.init([]))
    end

    test "workspace owned by another org -> 409 and org A keeps its binding", %{
      user: user,
      org: org
    } do
      # Org A already owns the "acme" workspace.
      other = create_org("Acme A", "bb-takeover-owner")
      insert_workspace!("acme", other.id, "acme")

      # The attacker (member of org B) has OAuth access to the same workspace.
      Application.put_env(:harmont_api, :bitbucket_connect_opts,
        sync?: false,
        exchange_fun: fn _id, _secret, "abc123" ->
          {:ok, %{access_token: "at", refresh_token: "rt", expires_in: 7200}}
        end,
        workspaces_fun: fn "at" -> {:ok, [%{slug: "acme", name: "Acme"}]} end
      )

      state = sign_state(user.id, org.slug)

      conn =
        post_connect_full(
          bearer_for(user),
          Jason.encode!(%{code: "abc123", state: state})
        )

      assert conn.status == 409
      assert decode(conn)["error"]["code"] == "bitbucket_installation_bound_elsewhere"

      # Org A still owns the workspace — no silent reassignment.
      assert Repo.get_by(VcsInstallation, external_id: "acme").organization_id == other.id
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/workspaces
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/bitbucket/workspaces" do
    test "lists the org's connected workspaces" do
      user = create_user("bblist@harmont.dev")
      org = member_org("Acme", "bb-list", user)
      insert_workspace!("acme", org.id, "acme")

      conn =
        req(:get, "/api/v0/organizations/bb-list/bitbucket/workspaces", bearer: bearer_for(user))

      assert conn.status == 200
      [ws] = decode(conn)["workspaces"]
      assert ws["slug"] == "acme"
      assert ws["name"] == "acme"
    end

    test "non-member org -> 404" do
      user = create_user("bbout@harmont.dev")
      _org = create_org("Secret", "bb-secret")

      conn =
        req(:get, "/api/v0/organizations/bb-secret/bitbucket/workspaces",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/workspaces/:id/repos
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/bitbucket/workspaces/:id/repos" do
    test "lists the workspace's synced repos" do
      user = create_user("bbrepos@harmont.dev")
      org = member_org("Acme", "bb-repos", user)
      inst = insert_workspace!("acme", org.id, "acme")
      insert_repo!(inst, "acme/widget")

      conn =
        req(:get, "/api/v0/organizations/bb-repos/bitbucket/workspaces/acme/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      [repo] = decode(conn)["repos"]
      assert repo["full_name"] == "acme/widget"
      assert repo["name"] == "widget"
      assert repo["default_branch"] == "main"
      assert repo["private"] == true
      assert repo["clone_url"] == "https://bitbucket.org/acme/widget.git"
    end

    test "workspace owned by another org -> 404" do
      user = create_user("bbrepos2@harmont.dev")
      _org = member_org("Acme", "bb-repos2", user)
      other = create_org("Other", "bb-repos-other")
      inst = insert_workspace!("other", other.id, "other")
      insert_repo!(inst, "other/secret")

      conn =
        req(:get, "/api/v0/organizations/bb-repos2/bitbucket/workspaces/other/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "bitbucket_workspace_not_found"
    end

    test "unknown workspace -> 404" do
      user = create_user("bbrepos3@harmont.dev")
      _org = member_org("Acme", "bb-repos3", user)

      conn =
        req(:get, "/api/v0/organizations/bb-repos3/bitbucket/workspaces/nope/repos",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "bitbucket_workspace_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /organizations/:org/bitbucket/workspaces/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /organizations/:org/bitbucket/workspaces/:id" do
    test "tombstones the workspace -> 204" do
      user = create_user("bbdel@harmont.dev")
      org = member_org("Acme", "bb-del", user)
      insert_workspace!("acme", org.id, "acme")

      conn =
        req(:delete, "/api/v0/organizations/bb-del/bitbucket/workspaces/acme",
          bearer: bearer_for(user)
        )

      assert conn.status == 204
      refute is_nil(Repo.get_by(VcsInstallation, external_id: "acme").deleted_at)
    end

    test "workspace owned by another org -> 404" do
      user = create_user("bbdel2@harmont.dev")
      _org = member_org("Acme", "bb-del2", user)
      other = create_org("Other", "bb-del-other")
      insert_workspace!("other", other.id, "other")

      conn =
        req(:delete, "/api/v0/organizations/bb-del2/bitbucket/workspaces/other",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "bitbucket_workspace_not_found"
    end
  end
end
