defmodule HarmontApi.BuildReadTest do
  @moduledoc """
  End-to-end tests for the build / job read endpoints and the
  build-scoped log-token mint.

  The bearer plug, the `OrgScope` / `PipelineScope` / `BuildScope` tenancy
  plugs, cursor pagination, the `Harmont.Builds` context, and the shared
  `Harmont.LogToken` all run for real against Postgres. The log-token
  assertions verify the minted token against `Harmont.LogToken` — the exact
  validator `HarmontWeb.LogToken` (the SSE stream's auth) delegates to, with
  the same shared secret.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Builds
  alias Harmont.Builds.Job
  alias Harmont.Builds.JobDep
  alias Harmont.Orgs
  alias Harmont.Pipelines

  # ---------------------------------------------------------------------------
  # Fixtures (mirroring the Task-2 pipeline tests)
  # ---------------------------------------------------------------------------

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp member_org(name, slug, user) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)
    org
  end

  defp create_pipeline(org, slug) do
    {:ok, pipeline} =
      Pipelines.create_pipeline(
        org,
        %{name: slug, slug: slug, repository: "github.com/acme/repo", default_branch: "main"},
        Repo
      )

    pipeline
  end

  defp create_build(pipeline, attrs \\ %{}) do
    {:ok, build} =
      Builds.create_build(pipeline, Map.merge(%{source: "api"}, attrs), Repo)

    build
  end

  defp create_job(build, step_key, attrs \\ %{}) do
    base = %{
      build_id: build.id,
      step_key: step_key,
      command: "echo #{step_key}",
      state: "pending"
    }

    {:ok, job} = %Job{} |> Job.changeset(Map.merge(base, attrs)) |> Repo.insert()
    job
  end

  defp create_dep(dependent, prerequisite, kind) do
    {:ok, dep} =
      %JobDep{}
      |> JobDep.changeset(%{
        dependent_id: dependent.id,
        prerequisite_id: prerequisite.id,
        kind: kind
      })
      |> Repo.insert()

    dep
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

  defp get_json(path, opts \\ []), do: req(:get, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp base(pipeline_slug), do: "/api/v0/organizations/acme/pipelines/#{pipeline_slug}"

  # ---------------------------------------------------------------------------
  # GET …/builds — list (paginated, newest first)
  # ---------------------------------------------------------------------------

  describe "GET …/builds" do
    test "lists builds newest first with pagination shape" do
      user = create_user("blist@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")

      b1 = create_build(pipeline)
      b2 = create_build(pipeline)
      b3 = create_build(pipeline)

      conn = get_json(base("p") <> "/builds", bearer: bearer_for(user))
      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "data")
      assert Map.has_key?(body, "next_cursor")
      numbers = Enum.map(body["data"], & &1["number"])
      assert numbers == [b3.number, b2.number, b1.number]
      assert is_nil(body["next_cursor"])
    end

    test "respects limit and returns a cursor; second page resumes newest-first" do
      user = create_user("bpage@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")

      _b1 = create_build(pipeline)
      _b2 = create_build(pipeline)
      b3 = create_build(pipeline)

      conn = get_json(base("p") <> "/builds?limit=2", bearer: bearer_for(user))
      body = decode(conn)
      assert Enum.map(body["data"], & &1["number"]) == [b3.number, b3.number - 1]
      assert is_binary(body["next_cursor"])

      conn2 =
        get_json(base("p") <> "/builds?limit=2&cursor=#{body["next_cursor"]}",
          bearer: bearer_for(user)
        )

      body2 = decode(conn2)
      assert Enum.map(body2["data"], & &1["number"]) == [b3.number - 2]
      assert is_nil(body2["next_cursor"])
    end

    test "only the scoped pipeline's builds appear" do
      user = create_user("biso@harmont.dev")
      org = member_org("Acme", "acme", user)
      p1 = create_pipeline(org, "p1")
      p2 = create_pipeline(org, "p2")

      _a = create_build(p1)
      _b = create_build(p2)

      conn = get_json(base("p1") <> "/builds", bearer: bearer_for(user))
      assert length(decode(conn)["data"]) == 1
    end

    test "non-member org -> 404" do
      user = create_user("bout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn = get_json(base("p") <> "/builds", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn = get_json("/api/v0/organizations/acme/pipelines/p/builds")
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # GET …/builds/:number — show
  # ---------------------------------------------------------------------------

  describe "GET …/builds/:number" do
    test "returns the build JSON" do
      user = create_user("bshow@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")
      build = create_build(pipeline, %{branch: "main", commit: "deadbeef", message: "hi"})

      conn = get_json(base("p") <> "/builds/#{build.number}", bearer: bearer_for(user))
      assert conn.status == 200
      body = decode(conn)
      assert body["number"] == build.number
      assert body["state"] == "scheduled"
      assert body["source"] == "api"
      assert body["branch"] == "main"
      assert body["commit"] == "deadbeef"
      assert body["message"] == "hi"
      assert is_binary(body["created_at"])
    end

    test "unknown number -> 404 build_not_found" do
      user = create_user("bmiss@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn = get_json(base("p") <> "/builds/999", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "build_not_found"
    end

    test "build number from another pipeline -> 404 (tenancy)" do
      user = create_user("bcross@harmont.dev")
      org = member_org("Acme", "acme", user)
      p1 = create_pipeline(org, "p1")
      _p2 = create_pipeline(org, "p2")
      b = create_build(p1)

      # b.number exists in p1 only; ask p2 for it.
      conn = get_json(base("p2") <> "/builds/#{b.number}", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "build_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # Jobs
  # ---------------------------------------------------------------------------

  describe "GET …/builds/:number/jobs and /jobs/:job_id" do
    setup do
      user = create_user("jobs@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")
      build = create_build(pipeline)
      j1 = create_job(build, "a", %{state: "passed", exit_code: 0})
      j2 = create_job(build, "b")
      # j2 (b) depends on j1 (a): one DAG edge for the depends_on assertions.
      create_dep(j2, j1, "depends_on")
      {:ok, user: user, build: build, j1: j1, j2: j2}
    end

    test "lists the build's jobs in topological order with depends_on edges", %{
      user: user,
      build: build,
      j1: j1,
      j2: j2
    } do
      conn = get_json(base("p") <> "/builds/#{build.number}/jobs", bearer: bearer_for(user))
      assert conn.status == 200
      data = conn |> decode() |> Map.fetch!("data")
      ids = Enum.map(data, & &1["id"])
      assert Enum.sort(ids) == Enum.sort([j1.id, j2.id])
      # Topological: prerequisite j1 (a) precedes dependent j2 (b).
      assert Enum.find_index(ids, &(&1 == j1.id)) < Enum.find_index(ids, &(&1 == j2.id))

      by_id = Map.new(data, &{&1["id"], &1})
      assert by_id[j1.id]["depends_on"] == []
      assert by_id[j2.id]["depends_on"] == [j1.id]
    end

    test "shows a single job with its depends_on edges", %{
      user: user,
      build: build,
      j1: j1,
      j2: j2
    } do
      conn =
        get_json(base("p") <> "/builds/#{build.number}/jobs/#{j1.id}", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert body["id"] == j1.id
      assert body["state"] == "passed"
      assert body["exit_code"] == 0
      assert body["command"] == "echo a"
      assert body["depends_on"] == []

      conn2 =
        get_json(base("p") <> "/builds/#{build.number}/jobs/#{j2.id}", bearer: bearer_for(user))

      assert decode(conn2)["depends_on"] == [j1.id]
    end

    test "job from another build -> 404 (tenancy)", %{user: user, build: build} do
      org = Orgs.fetch_org_scoped(user, "acme", Repo) |> elem(1)
      other_pipeline = create_pipeline(org, "other")
      other_build = create_build(other_pipeline)
      foreign = create_job(other_build, "x")

      conn =
        get_json(base("p") <> "/builds/#{build.number}/jobs/#{foreign.id}",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "job_not_found"
    end

    test "unknown job id -> 404", %{user: user, build: build} do
      conn =
        get_json(base("p") <> "/builds/#{build.number}/jobs/#{Ecto.UUID.generate()}",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
    end
  end

  # ---------------------------------------------------------------------------
  # Log token — must be accepted by harmont_web's validator
  # ---------------------------------------------------------------------------

  describe "GET …/builds/:number/log-token" do
    test "returns a token the SSE stream's validator accepts" do
      user = create_user("logtok@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")
      build = create_build(pipeline)

      conn = get_json(base("p") <> "/builds/#{build.number}/log-token", bearer: bearer_for(user))
      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert is_binary(body["expires_at"])

      # The web edge (HarmontWeb.LogToken) delegates verification to the shared
      # Harmont.LogToken with the same secret resolver. Verifying here against
      # that exact validator + secret proves the SSE stream would accept this
      # token; it must return THIS build's external_build_id.
      assert {:ok, build.external_build_id} ==
               Harmont.LogToken.verify(body["token"], Harmont.LogToken.secret())
    end

    test "unknown build -> 404" do
      user = create_user("logmiss@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn = get_json(base("p") <> "/builds/12345/log-token", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "build_not_found"
    end
  end
end
