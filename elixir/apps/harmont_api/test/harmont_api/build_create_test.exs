defmodule HarmontApi.BuildCreateTest do
  @moduledoc """
  End-to-end tests for the build CREATE endpoint (pre-rendered IR path).

  `POST …/pipelines/:pipeline/builds` creates the single build row via
  `Harmont.Builds.create_build` and starts execution in-process through
  `Harmont.Engine.Api.materialize_and_start` (the bridge collapse — no gRPC).
  The bearer plug, the org/pipeline tenancy plugs, the contexts, and the
  engine materialise+start path all run for real against Postgres. Oban runs
  in `:manual` mode (config/test.exs), so the enqueued root `CI.JobRunner` is
  asserted with `assert_enqueued` rather than executed.
  """
  use HarmontApi.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Orgs
  alias Harmont.Pipelines
  alias Harmont.Pipelines.RunnerToken

  # A small, valid v0 flat IR (two command steps separated by a wait) — copied
  # from the engine's `Harmont.Engine.ApiTest` fixture shape.
  @valid_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "steps" => [
                %{"type" => "command", "key" => "a", "cmd" => "echo a"},
                %{"type" => "wait"},
                %{"type" => "command", "key" => "b", "cmd" => "echo b", "builds_in" => "a"}
              ]
            })

  # An IR the planner rejects (wrong version).
  @bad_ir Jason.encode!(%{"version" => "1"})

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp member_org(name, slug, user, credit_cents \\ 100_000) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)

    if credit_cents > 0 do
      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: credit_cents, source: :admin_grant},
          Repo
        )
    end

    org
  end

  defp create_pipeline(org, slug, attrs \\ %{}) do
    {:ok, pipeline} =
      Pipelines.create_pipeline(
        org,
        Map.merge(
          %{name: slug, slug: slug, repository: "github.com/acme/repo", default_branch: "main"},
          attrs
        ),
        Repo
      )

    pipeline
  end

  # POST helper mirroring the Task-1/2 router-test convention: for a body we set
  # `body_params` and merge it into `params` ourselves (no JSON decoder runs).
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

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp post_json(path, opts), do: req(:post, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp builds_path(org_slug, pipeline_slug),
    do: "/api/v0/organizations/#{org_slug}/pipelines/#{pipeline_slug}/builds"

  defp org_builds_path(org_slug), do: "/api/v0/organizations/#{org_slug}/builds"

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "POST …/builds (pre-rendered IR)" do
    test "creates the build, materialises jobs, enqueues the root runner, returns 201" do
      user = create_user("bcreate@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("acme", "p"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "source" => "api",
            "pipeline_ir" => @valid_ir,
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 201
      body = decode(conn)

      # The build reports its pipeline's global slug so the CLI can watch/cancel.
      assert body["pipeline_slug"] == "p"

      # The response is the build, with an allocated number; the runner token is
      # NOT leaked to the user.
      assert is_integer(body["number"])
      assert body["branch"] == "main"
      assert body["commit"] == "deadbeef"
      assert body["source"] == "api"
      refute Map.has_key?(body, "runner_token")
      refute Map.has_key?(body, "token")

      # Exactly one build row, owned by the pipeline + user.
      [build] = Repo.all(Build)
      assert build.pipeline_id == pipeline.id
      assert build.created_by_id == user.id
      assert build.number == body["number"]
      assert build.source_url == "https://example/src.tgz"
      assert build.default_image == "ubuntu:24.04"
      assert is_binary(build.runner_token_hash)

      # Jobs materialised for the build.
      jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
      assert length(jobs) == 2

      # A runner token was issued + stored (hashed) — never returned.
      assert [%RunnerToken{} = token] = Repo.all(RunnerToken)
      assert token.build_id == build.id

      # Root runner enqueued (Oban manual mode).
      assert_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end

    test "defaults source to \"api\" when omitted" do
      user = create_user("bdefault@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("acme", "p"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "pipeline_ir" => @valid_ir,
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 201
      assert decode(conn)["source"] == "api"
      [build] = Repo.all(Build)
      assert build.source == "api"
    end

    test "source_b64 mints the internal source_url from x-forwarded-proto (no http→https redirect)" do
      # Regression: behind the TLS-terminating LB the request arrives as http:80,
      # so a conn-derived source_url is `http://host:80/...`. The LB 301-redirects
      # that to https and the agent's HTTP client drops the Authorization header
      # across the redirect → the in-VM source fetch 401s → `agent_connect_deadline`.
      # The minted URL must use the forwarded (https) scheme and carry no :80 port.
      user = create_user("bsrcb64@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("acme", "p"),
          bearer: bearer_for(user),
          headers: [{"x-forwarded-proto", "https"}],
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "pipeline_ir" => @valid_ir,
            "source_b64" => Base.encode64("a-fake-source-tarball")
          }
        )

      assert conn.status == 201
      [build] = Repo.all(Build)

      assert build.source_url ==
               "https://www.example.com/api/v0/internal/builds/#{build.external_build_id}/source.tar.gz"

      refute String.starts_with?(build.source_url, "http://")
      refute build.source_url =~ ":80/"
    end
  end

  # ---------------------------------------------------------------------------
  # In-sandbox render path (no pre-rendered IR)
  # ---------------------------------------------------------------------------

  describe "POST …/builds (no pipeline_ir → in-sandbox render)" do
    setup do
      prev_backend = Application.get_env(:harmont_engine, :render_backend)

      on_exit(fn ->
        if prev_backend do
          Application.put_env(:harmont_engine, :render_backend, prev_backend)
        else
          Application.delete_env(:harmont_engine, :render_backend)
        end

        Application.delete_env(:harmont_engine, :canned_render_execs)
        Application.delete_env(:harmont_engine, :canned_render_provision)
      end)

      # Render in a fake VM backend (no real sandbox): exec 1 = source fetch (no
      # stdout), exec 2 = render (the IR on stdout).
      Application.put_env(:harmont_engine, :render_backend, HarmontApi.CannedRenderBackend)

      Application.put_env(:harmont_engine, :canned_render_execs, [
        %{exit_code: 0, stdout: "", stderr: ""},
        %{exit_code: 0, stdout: @valid_ir, stderr: ""}
      ])

      :ok
    end

    test "renders IR in the sandbox then materialises + starts the build, returns 201" do
      user = create_user("brender@harmont.dev")
      org = member_org("Acme", "acme", user)
      pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("acme", "p"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "source" => "api",
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 201
      body = decode(conn)
      assert is_integer(body["number"])
      assert body["branch"] == "main"

      # One build row, owned by the pipeline, with the rendered IR materialised.
      [build] = Repo.all(Build)
      assert build.pipeline_id == pipeline.id
      assert build.default_image == "ubuntu:24.04"
      assert is_binary(build.runner_token_hash)

      jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
      assert length(jobs) == 2

      assert [%RunnerToken{} = token] = Repo.all(RunnerToken)
      assert token.build_id == build.id

      assert_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end
  end

  # ---------------------------------------------------------------------------
  # Manual disabled
  # ---------------------------------------------------------------------------

  describe "allow_manual gate" do
    test "manual source against a manual-disabled pipeline yields 403 pipeline_manual_disabled" do
      user = create_user("bmanual@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "locked", %{allow_manual: false})

      conn =
        post_json(builds_path("acme", "locked"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "source" => "api",
            "pipeline_ir" => @valid_ir,
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "pipeline_manual_disabled"

      # No build row created.
      assert Repo.aggregate(Build, :count) == 0
      refute_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end
  end

  # ---------------------------------------------------------------------------
  # Billing gate
  # ---------------------------------------------------------------------------

  describe "billing gate" do
    test "POST …/builds returns 402 when the org balance is <= $0" do
      user = create_user("nocredit@harmont.dev")
      org = member_org("No Credit", "no-credit", user, 0)
      pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("no-credit", "p"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "source" => "api",
            "pipeline_ir" => @valid_ir,
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 402
      assert decode(conn)["error"]["code"] == "billing_insufficient_balance"

      # The gate runs BEFORE creation: no build row, nothing enqueued.
      assert Repo.aggregate(from(b in Build, where: b.pipeline_id == ^pipeline.id), :count) == 0
      refute_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end
  end

  # ---------------------------------------------------------------------------
  # Plan rejected
  # ---------------------------------------------------------------------------

  describe "plan-rejected IR" do
    test "an invalid IR yields 422 build_plan_rejected; the build row exists with error fields" do
      user = create_user("breject@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn =
        post_json(builds_path("acme", "p"),
          bearer: bearer_for(user),
          body: %{
            "branch" => "main",
            "commit" => "deadbeef",
            "source" => "api",
            "pipeline_ir" => @bad_ir,
            "source_url" => "https://example/src.tgz"
          }
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "build_plan_rejected"

      # The build row exists (a failed build) with its error fields set.
      [build] = Repo.all(Build)
      assert build.state == "failed"
      assert build.error_code == "bad_version"
      assert build.error_message =~ "version"

      assert Repo.all(from(j in Job, where: j.build_id == ^build.id)) == []
      refute_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy
  # ---------------------------------------------------------------------------

  describe "tenancy" do
    test "non-member org → 404" do
      member = create_user("bowner@harmont.dev")
      org = member_org("Secret", "secret", member)
      _pipeline = create_pipeline(org, "p")

      outsider = create_user("boutsider@harmont.dev")

      conn =
        post_json(builds_path("secret", "p"),
          bearer: bearer_for(outsider),
          body: %{"branch" => "main", "commit" => "c", "pipeline_ir" => @valid_ir}
        )

      assert conn.status == 404
      assert Repo.aggregate(Build, :count) == 0
    end

    test "unknown pipeline in a member org → 404" do
      user = create_user("bnopipe@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json(builds_path("acme", "nope"),
          bearer: bearer_for(user),
          body: %{"branch" => "main", "commit" => "c", "pipeline_ir" => @valid_ir}
        )

      assert conn.status == 404
      assert Repo.aggregate(Build, :count) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Resolve by repo + source slug
  # ---------------------------------------------------------------------------

  describe "POST /organizations/:org/builds (resolve by repo + source slug)" do
    test "resolves the pipeline by (repo_name, source_slug) and returns 201" do
      user = create_user("bysrc@harmont.dev")
      org = member_org("Acme", "acme", user)

      _pipeline =
        create_pipeline(org, "harmont-dev-acme-ci", %{
          repo_name: "harmont-dev/acme",
          source_slug: "ci"
        })

      conn =
        post_json(org_builds_path("acme"),
          bearer: bearer_for(user),
          body: %{
            "repo_name" => "harmont-dev/acme",
            "source_slug" => "ci",
            "branch" => "main",
            "commit" => "deadbeef",
            "pipeline_ir" => @valid_ir
          }
        )

      assert conn.status == 201
      body = decode(conn)
      assert is_integer(body["number"])
      # The response carries the resolved GLOBAL slug, not the source slug.
      assert body["pipeline_slug"] == "harmont-dev-acme-ci"
    end

    test "returns 404 pipeline_not_found when no pipeline matches" do
      user = create_user("bysrc404@harmont.dev")
      org = member_org("Acme", "acme", user)

      _pipeline =
        create_pipeline(org, "harmont-dev-acme-ci", %{
          repo_name: "harmont-dev/acme",
          source_slug: "ci"
        })

      conn =
        post_json(org_builds_path("acme"),
          bearer: bearer_for(user),
          body: %{
            "repo_name" => "harmont-dev/acme",
            "source_slug" => "release",
            "branch" => "main",
            "commit" => "deadbeef",
            "pipeline_ir" => @valid_ir
          }
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "pipeline_not_found"
    end

    test "honors the allow_manual gate (403)" do
      user = create_user("bysrclocked@harmont.dev")
      org = member_org("Acme", "acme", user)

      _pipeline =
        create_pipeline(org, "harmont-dev-acme-ci", %{
          repo_name: "harmont-dev/acme",
          source_slug: "ci",
          allow_manual: false
        })

      conn =
        post_json(org_builds_path("acme"),
          bearer: bearer_for(user),
          body: %{
            "repo_name" => "harmont-dev/acme",
            "source_slug" => "ci",
            "source" => "api",
            "branch" => "main",
            "commit" => "deadbeef",
            "pipeline_ir" => @valid_ir
          }
        )

      assert conn.status == 403
      assert decode(conn)["error"]["code"] == "pipeline_manual_disabled"
    end
  end
end
