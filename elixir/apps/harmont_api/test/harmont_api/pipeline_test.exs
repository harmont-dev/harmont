defmodule HarmontApi.PipelineTest do
  @moduledoc """
  End-to-end tests for the pipeline endpoints.

  The bearer plug, the `OrgScope` + `PipelineScope` tenancy plugs, cursor
  pagination, and the `Harmont.Pipelines` context all run for real against
  Postgres.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Orgs
  alias Harmont.Pipelines

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

  # Isolated router calls (no endpoint parsers), so we feed query/body params
  # directly: GET uses `fetch_query_params`; for POST we set `conn.params` and
  # `conn.body_params` ourselves (mirroring the Task-1 organization tests).
  defp req(method, path, opts) do
    conn =
      method
      |> Plug.Test.conn(path, "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()

    conn =
      case Keyword.get(opts, :body) do
        nil ->
          conn

        body ->
          %{conn | body_params: body, params: Map.merge(conn.params, body)}
      end

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp get_json(path, opts \\ []), do: req(:get, path, opts)
  defp post_json(path, opts), do: req(:post, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # POST /organizations/:org/pipelines
  # ---------------------------------------------------------------------------

  describe "POST /organizations/:org/pipelines" do
    test "valid -> 201 with the pipeline, slug derived from name" do
      user = create_user("creator@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/organizations/acme/pipelines",
          bearer: bearer_for(user),
          body: %{
            "name" => "My Pipeline",
            "repository" => "github.com/acme/repo",
            "default_branch" => "main",
            "description" => "the thing"
          }
        )

      assert conn.status == 201
      body = decode(conn)
      assert body["slug"] == "my-pipeline"
      assert body["name"] == "My Pipeline"
      assert body["repository"] == "github.com/acme/repo"
      assert body["default_branch"] == "main"
      assert body["description"] == "the thing"
      assert body["visibility"] == "private"
      assert body["allow_manual"] == true
      assert is_binary(body["created_at"])
    end

    test "duplicate slug -> 422 envelope" do
      user = create_user("dup@harmont.dev")
      org = member_org("Acme", "acme-dup", user)

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "Taken", repository: "r", default_branch: "main"},
          Repo
        )

      conn =
        post_json("/api/v0/organizations/acme-dup/pipelines",
          bearer: bearer_for(user),
          body: %{"name" => "Taken", "repository" => "r2", "default_branch" => "main"}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "pipeline_slug_taken"
    end

    test "non-member org -> 404" do
      user = create_user("outsider@harmont.dev")
      _org = create_org("Secret", "secret-create")

      conn =
        post_json("/api/v0/organizations/secret-create/pipelines",
          bearer: bearer_for(user),
          body: %{"name" => "P", "repository" => "r", "default_branch" => "main"}
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      _org = create_org("Pub", "pub-create")

      conn =
        post_json("/api/v0/organizations/pub-create/pipelines",
          body: %{"name" => "P", "repository" => "r", "default_branch" => "main"}
        )

      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end

    test "derives and returns repo_name from the repository" do
      user = create_user("repo-name@harmont.dev")
      _org = member_org("Acme", "acme-rn", user)

      conn =
        post_json("/api/v0/organizations/acme-rn/pipelines",
          bearer: bearer_for(user),
          body: %{
            "name" => "My Pipeline",
            "repository" => "https://github.com/acme/core.git",
            "default_branch" => "main"
          }
        )

      assert conn.status == 201
      assert decode(conn)["repo_name"] == "acme/core"
    end

    test "accepts an explicit repo_name" do
      user = create_user("repo-name2@harmont.dev")
      _org = member_org("Acme", "acme-rn2", user)

      conn =
        post_json("/api/v0/organizations/acme-rn2/pipelines",
          bearer: bearer_for(user),
          body: %{
            "name" => "My Pipeline",
            "repository" => "https://github.com/acme/core.git",
            "default_branch" => "main",
            "repo_name" => "team/widget"
          }
        )

      assert conn.status == 201
      assert decode(conn)["repo_name"] == "team/widget"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/pipelines
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/pipelines" do
    test "lists non-archived pipelines with pagination shape (archived excluded)" do
      user = create_user("lister@harmont.dev")
      org = member_org("Acme", "acme-list", user)

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "Alpha", slug: "alpha", repository: "r", default_branch: "main"},
          Repo
        )

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "Beta", slug: "beta", repository: "r", default_branch: "main"},
          Repo
        )

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "Gone", slug: "gone", repository: "r", default_branch: "main", archived: true},
          Repo
        )

      conn = get_json("/api/v0/organizations/acme-list/pipelines", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "data")
      assert Map.has_key?(body, "next_cursor")
      assert is_nil(body["next_cursor"])
      slugs = Enum.map(body["data"], & &1["slug"])
      assert "alpha" in slugs
      assert "beta" in slugs
      refute "gone" in slugs
      assert length(slugs) == 2
    end

    test "respects limit and returns a cursor when more pages remain" do
      user = create_user("pager@harmont.dev")
      org = member_org("Acme", "acme-page", user)

      for i <- 1..3 do
        {:ok, _} =
          Pipelines.create_pipeline(
            org,
            %{name: "P#{i}", slug: "p#{i}", repository: "r", default_branch: "main"},
            Repo
          )
      end

      conn =
        get_json("/api/v0/organizations/acme-page/pipelines?limit=2", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert length(body["data"]) == 2
      assert is_binary(body["next_cursor"])

      conn2 =
        get_json(
          "/api/v0/organizations/acme-page/pipelines?limit=2&cursor=#{body["next_cursor"]}",
          bearer: bearer_for(user)
        )

      body2 = decode(conn2)
      assert length(body2["data"]) == 1
      assert is_nil(body2["next_cursor"])
    end

    test "non-member org -> 404" do
      user = create_user("outsider-list@harmont.dev")
      _org = create_org("Secret", "secret-list")

      conn = get_json("/api/v0/organizations/secret-list/pipelines", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/pipelines/:pipeline
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org/pipelines/:pipeline" do
    test "member -> 200 with the pipeline JSON" do
      user = create_user("getter@harmont.dev")
      org = member_org("Acme", "acme-get", user)

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "My Pipeline", repository: "r", default_branch: "main"},
          Repo
        )

      conn =
        get_json("/api/v0/organizations/acme-get/pipelines/my-pipeline", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert body["slug"] == "my-pipeline"
      assert body["name"] == "My Pipeline"
    end

    test "unknown pipeline -> 404 (pipeline_not_found)" do
      user = create_user("unknown@harmont.dev")
      _org = member_org("Acme", "acme-unknown", user)

      conn =
        get_json("/api/v0/organizations/acme-unknown/pipelines/nope", bearer: bearer_for(user))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "pipeline_not_found"
    end

    test "pipeline in another org -> 404 (tenancy)" do
      owner = create_user("owner@harmont.dev")
      owner_org = member_org("Owner", "owner-org", owner)

      {:ok, _} =
        Pipelines.create_pipeline(
          owner_org,
          %{name: "Theirs", slug: "theirs", repository: "r", default_branch: "main"},
          Repo
        )

      outsider = create_user("nope@harmont.dev")
      _their_org = member_org("Mine", "mine-org", outsider)

      # Outsider asks their own org for a slug that exists only in owner-org.
      conn =
        get_json("/api/v0/organizations/mine-org/pipelines/theirs", bearer: bearer_for(outsider))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "pipeline_not_found"
    end

    test "non-member org (any pipeline route) -> 404" do
      user = create_user("outsider-get@harmont.dev")
      other = create_org("Secret", "secret-get")

      {:ok, _} =
        Pipelines.create_pipeline(
          other,
          %{name: "Hidden", slug: "hidden", repository: "r", default_branch: "main"},
          Repo
        )

      conn =
        get_json("/api/v0/organizations/secret-get/pipelines/hidden", bearer: bearer_for(user))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      org = create_org("Pub", "pub-get")

      {:ok, _} =
        Pipelines.create_pipeline(
          org,
          %{name: "P", slug: "p", repository: "r", default_branch: "main"},
          Repo
        )

      conn = get_json("/api/v0/organizations/pub-get/pipelines/p")
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end
  end
end
