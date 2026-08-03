defmodule HarmontWeb.GithubInternalTest do
  @moduledoc """
  End-to-end coverage of the internal repo/file proxy endpoints that
  harmont-api calls (it holds no GitHub App private key, so it asks this app to
  fetch repo files using an installation token). Driven through the real
  Endpoint pipeline so the `:github_internal` endpoint plug, Bearer auth, the
  installation-token cache, and the GitHub client all participate.

  ConnCase sandboxes `Harmont.Repo` (the single unified repo); all test data
  (installations, repos, Oban jobs) lives there.
  """
  use HarmontWeb.ConnCase, async: false

  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings
  alias Harmont.Repo, as: CoreRepo
  alias Harmont.Vcs.Installation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @internal_token "internal-secret-0123456789"

  setup do
    prev = :persistent_term.get({Runtime, :settings}, :__unset__)

    Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
      plug: {Req.Test, GithubClient}
    )

    on_exit(fn ->
      Application.delete_env(:harmont_gh_app, :gh_app_github_req_options)

      case prev do
        :__unset__ -> :persistent_term.erase({Runtime, :settings})
        s -> :persistent_term.put({Runtime, :settings}, s)
      end
    end)

    :ok
  end

  defp put_settings(internal_token) do
    Runtime.put_settings(%Settings{
      app_id: 1,
      webhook_secret: "a-sufficiently-long-secret",
      private_key_pem: "pem",
      github_api_base_url: "https://api.github.test",
      internal_token: internal_token
    })
  end

  defp start_tokens do
    mint = fn _id -> {:ok, "inst-tok", DateTime.add(DateTime.utc_now(), 3600, :second)} end
    start_supervised!({InstallationTokens, mint_fun: mint})
  end

  describe "auth" do
    test "an internal token is configured but the request has no Bearer -> 401", %{conn: conn} do
      put_settings(@internal_token)

      conn = get(conn, "/api/installations/7/repos/acme/widget/file?path=.hm/pipeline.py")
      assert conn.status == 401
    end

    test "a wrong Bearer token -> 401", %{conn: conn} do
      put_settings(@internal_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get("/api/installations/7/repos/acme/widget/file?path=.hm/pipeline.py")

      assert conn.status == 401
    end
  end

  describe "file fetch" do
    test "authorized fetch returns 200 + the raw file bytes", %{conn: conn} do
      put_settings(@internal_token)
      start_tokens()

      Req.Test.stub(GithubClient, fn c ->
        assert c.method == "GET"
        assert c.request_path == "/repos/acme/widget/contents/.hm/pipeline.py"
        Plug.Conn.send_resp(c, 200, "print('hi')\n")
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations/7/repos/acme/widget/file?path=.hm/pipeline.py&ref=main")

      assert conn.status == 200
      assert conn.resp_body == "print('hi')\n"
    end

    test "dev mode (no internal token) allows the request", %{conn: conn} do
      put_settings(nil)
      start_tokens()

      Req.Test.stub(GithubClient, fn c ->
        Plug.Conn.send_resp(c, 200, "dev-bytes")
      end)

      conn =
        get(conn, "/api/installations/7/repos/acme/widget/file?path=.hm/pipeline.py")

      assert conn.status == 200
      assert conn.resp_body == "dev-bytes"
    end

    test "missing path query parameter -> 400", %{conn: conn} do
      put_settings(@internal_token)
      start_tokens()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations/7/repos/acme/widget/file")

      assert conn.status == 400
    end

    test "a 404 from GitHub maps to 404", %{conn: conn} do
      put_settings(@internal_token)
      start_tokens()

      Req.Test.stub(GithubClient, fn c ->
        Plug.Conn.send_resp(c, 404, ~s({"message":"Not Found"}))
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations/7/repos/acme/widget/file?path=nope.py")

      assert conn.status == 404
    end
  end

  describe "installations list" do
    defp seed_installation(installation_id, account_login, account_type, opts \\ []) do
      attrs =
        %{
          provider: "github",
          external_id: to_string(installation_id),
          account_name: account_login,
          account_kind: account_type,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        |> then(fn a ->
          case Keyword.get(opts, :deleted_at) do
            nil -> a
            ts -> Map.put(a, :deleted_at, ts)
          end
        end)

      {:ok, inst} =
        %Installation{}
        |> Ecto.Changeset.cast(attrs, [
          :provider,
          :external_id,
          :account_name,
          :account_kind,
          :deleted_at,
          :created_at,
          :updated_at
        ])
        |> CoreRepo.insert()

      inst
    end

    test "authorized list returns the seeded installations as a camelCase JSON array",
         %{conn: conn} do
      put_settings(@internal_token)

      seed_installation(7, "acme", "Organization")
      seed_installation(11, "octo", "User")
      seed_installation(99, "gone", "Organization", deleted_at: DateTime.utc_now())

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations")

      assert conn.status == 200
      installations = Jason.decode!(conn.resp_body)
      assert is_list(installations)

      # Index by installationId. The core test DB may hold other committed
      # installations, so assert on the seeded rows specifically rather than the
      # total count.
      by_id = Map.new(installations, &{&1["installationId"], &1})

      assert by_id[7] == %{
               "installationId" => 7,
               "accountLogin" => "acme",
               "accountType" => "Organization"
             }

      assert by_id[11] == %{
               "installationId" => 11,
               "accountLogin" => "octo",
               "accountType" => "User"
             }

      # Soft-deleted row is excluded.
      refute Map.has_key?(by_id, 99)
    end

    test "a wrong Bearer token on the list path -> 401", %{conn: conn} do
      put_settings(@internal_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get("/api/installations")

      assert conn.status == 401
    end
  end

  describe "repos list" do
    test "authorized list returns the seeded vcs_repo rows as JSON", %{conn: conn} do
      put_settings(@internal_token)

      {:ok, inst} =
        %Installation{}
        |> Ecto.Changeset.cast(
          %{
            provider: "github",
            external_id: "7",
            account_name: "acme",
            account_kind: "Organization",
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          [:provider, :external_id, :account_name, :account_kind, :created_at, :updated_at]
        )
        |> CoreRepo.insert()

      {:ok, _repo} =
        %VcsRepo{}
        |> Ecto.Changeset.cast(
          %{
            installation_id: inst.id,
            provider: "github",
            external_repo_id: "999",
            full_name: "acme/widget",
            name: "widget",
            owner: "acme",
            clone_url: "https://github.com/acme/widget.git",
            default_branch: "main",
            private: false,
            last_synced_at: DateTime.utc_now(),
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          [
            :installation_id,
            :provider,
            :external_repo_id,
            :full_name,
            :name,
            :owner,
            :clone_url,
            :default_branch,
            :private,
            :last_synced_at,
            :created_at,
            :updated_at
          ]
        )
        |> CoreRepo.insert()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations/7/repos")

      assert conn.status == 200
      [repo] = Jason.decode!(conn.resp_body)
      assert repo["id"] == 999
      assert repo["fullName"] == "acme/widget"
      assert repo["name"] == "widget"
      assert repo["owner"] == "acme"
      assert repo["cloneUrl"] == "https://github.com/acme/widget.git"
      assert repo["defaultBranch"] == "main"
      assert repo["private"] == false
    end

    test "an unknown installation lists no repos (empty array)", %{conn: conn} do
      put_settings(@internal_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@internal_token}")
        |> get("/api/installations/99999/repos")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end
  end
end
