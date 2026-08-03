defmodule Harmont.Integration.BuildLifecycleE2ETest do
  @moduledoc """
  End-to-end build create -> execute -> cancel through the REAL composed endpoint.

  This drives the full Plan-4 domain lifecycle against `HarmontWeb.Endpoint` —
  the single endpoint that mounts `HarmontApi.Router` at `/api/v0` — using
  `Phoenix.ConnTest` (no live listener). It proves the bridge collapse works
  in-process through the composed system, with NO gRPC anywhere:

    1. `POST /api/v0/organizations/:org/pipelines` -> 201 (creates a pipeline).
    2. `POST …/pipelines/:slug/builds` with pre-rendered v0 IR -> 201; the build
       row is created and execution is started in-process via
       `Harmont.Engine.Api.materialize_and_start` (jobs materialised, root
       `CI.JobRunner` enqueued — asserted with `assert_enqueued`, since Oban is
       in `:manual` mode in test).
    3. `GET …/builds/:number` -> 200, state `scheduled`.
    4. `PUT …/builds/:number/cancel` -> 200, state `canceling`/`canceled`
       (cancel runs in-process via `Harmont.Engine.Cancel`).

  Everything below the HTTP edge — the `:authed` bearer plug, the org/pipeline/
  build tenancy plugs, the Plan-2 contexts, and the engine materialise + start
  + cancel paths — is the real composed system against Postgres. The session
  bearer is minted directly via `Harmont.Accounts.create_session_token` rather
  than the OAuth flow, to keep this test focused on the build lifecycle.
  """
  use HarmontWeb.ConnCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Orgs
  alias Harmont.Repo

  import Ecto.Query, only: [from: 2]

  # A small, valid v0 flat IR (two command steps separated by a wait) — the same
  # canned fixture shape used by the Task-5/6 build-create tests.
  @valid_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "steps" => [
                %{"type" => "command", "key" => "a", "cmd" => "echo a"},
                %{"type" => "wait"},
                %{"type" => "command", "key" => "b", "cmd" => "echo b", "builds_in" => "a"}
              ]
            })

  defp seed_user_org do
    {:ok, user} =
      Repo.insert(User.changeset(%User{}, %{name: "E2E", email: "build-e2e@harmont.dev"}))

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"}, Repo)
    {:ok, _membership} = Orgs.add_member(org, user, :member, Repo)

    # Fund the org so the build-creation balance gate (gates new pipeline runs on
    # org balance) admits the build; mirrors the API build tests' :admin_grant.
    {:ok, _} =
      Billing.insert_entry(
        %{organization_id: org.id, amount_cents: 100_000, source: :admin_grant},
        Repo
      )

    {raw_token, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    {user, org, "Bearer " <> raw_token}
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  test "create -> execute -> cancel a build in-process through HarmontWeb.Endpoint", %{conn: conn} do
    {user, _org, bearer} = seed_user_org()

    # 1. Create a pipeline.
    pipeline_conn =
      conn
      |> put_req_header("authorization", bearer)
      |> post_json("/api/v0/organizations/acme/pipelines", %{
        "name" => "Web",
        "repository" => "github.com/acme/repo",
        "default_branch" => "main"
      })

    assert pipeline_conn.status == 201
    pipeline_slug = json_response(pipeline_conn, 201)["slug"]
    assert is_binary(pipeline_slug) and pipeline_slug != ""

    builds_path = "/api/v0/organizations/acme/pipelines/#{pipeline_slug}/builds"

    # 2. Create a build with pre-rendered IR -> 201, execution started in-process.
    create_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> post_json(builds_path, %{
        "branch" => "main",
        "commit" => "deadbeef",
        "source" => "api",
        "pipeline_ir" => @valid_ir,
        "source_url" => "https://example/src.tgz"
      })

    assert create_conn.status == 201
    created = json_response(create_conn, 201)
    number = created["number"]
    assert is_integer(number)
    # The runner token is never leaked to the user.
    refute Map.has_key?(created, "runner_token")
    refute Map.has_key?(created, "token")

    # The single build row exists, owned by the user, with jobs materialised.
    [build] = Repo.all(Build)
    assert build.number == number
    assert build.created_by_id == user.id
    assert build.default_image == "ubuntu:24.04"
    assert is_binary(build.runner_token_hash)
    assert length(Repo.all(from(j in Job, where: j.build_id == ^build.id))) == 2

    # Execution started in-process: the root JobRunner is enqueued (Oban manual).
    assert_enqueued(worker: Harmont.Engine.CI.JobRunner)

    # 3. GET the build -> 200, scheduled.
    show_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> get("#{builds_path}/#{number}")

    assert show_conn.status == 200
    shown = json_response(show_conn, 200)
    assert shown["number"] == number
    assert shown["state"] == "scheduled"

    # 4. Cancel the build -> 200, canceling/canceled; cancel ran in-process.
    cancel_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> put("#{builds_path}/#{number}/cancel")

    assert cancel_conn.status == 200
    cancelled = json_response(cancel_conn, 200)
    assert cancelled["number"] == number
    assert cancelled["state"] in ~w(canceling canceled)

    reloaded = Repo.get!(Build, build.id)
    assert reloaded.cancel_requested == true
    assert reloaded.state in ~w(canceling canceled)
  end
end
