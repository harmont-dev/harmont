defmodule HarmontApi.BuildCancelTest do
  @moduledoc """
  End-to-end tests for the build CANCEL endpoint.

  `PUT …/pipelines/:pipeline/builds/:number/cancel` cancels an in-flight build
  in-process via `Harmont.Engine.Api.cancel` (the bridge collapse — no gRPC) and
  returns the reloaded build. The bearer plug, the org/pipeline/build tenancy
  plugs, and the engine cancel cascade all run for real against Postgres. Oban
  runs in `:manual` mode (config/test.exs).
  """
  use HarmontApi.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Builds.Build
  alias Harmont.Orgs
  alias Harmont.Pipelines

  # A small, valid v0 flat IR (two command steps separated by a wait).
  @valid_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "steps" => [
                %{"type" => "command", "key" => "a", "cmd" => "echo a"},
                %{"type" => "wait"},
                %{"type" => "command", "key" => "b", "cmd" => "echo b", "builds_in" => "a"}
              ]
            })

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

  defp member_org(name, slug, user) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)

    # Builds are created through the POST endpoint, which is gated on org balance;
    # grant credit so the cancel tests can stand up a build to cancel.
    {:ok, _} =
      Billing.insert_entry(
        %{organization_id: org.id, amount_cents: 100_000, source: :admin_grant},
        Repo
      )

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

  defp post_json(path, opts), do: req(:post, path, opts)
  defp put_json(path, opts), do: req(:put, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp builds_path(org_slug, pipeline_slug),
    do: "/api/v0/organizations/#{org_slug}/pipelines/#{pipeline_slug}/builds"

  # Create a build through the Task-5 pre-rendered-IR path so it has a real
  # external_build_id + materialised jobs to cancel.
  defp create_build(org_slug, pipeline_slug, bearer) do
    conn =
      post_json(builds_path(org_slug, pipeline_slug),
        bearer: bearer,
        body: %{
          "branch" => "main",
          "commit" => "deadbeef",
          "source" => "api",
          "pipeline_ir" => @valid_ir,
          "source_url" => "https://example/src.tgz"
        }
      )

    assert conn.status == 201
    decode(conn)["number"]
  end

  # ---------------------------------------------------------------------------
  # Cancel
  # ---------------------------------------------------------------------------

  describe "PUT …/builds/:number/cancel" do
    test "cancels the build in-process and returns 200 with the canceling state" do
      user = create_user("bcancel@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      number = create_build("acme", "p", bearer_for(user))

      conn =
        put_json("#{builds_path("acme", "p")}/#{number}/cancel", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert body["number"] == number
      assert body["state"] in ~w(canceling canceled)

      # The cancel cascade ran: the build row reflects it.
      [build] = Repo.all(Build)
      assert build.cancel_requested == true
      assert build.state in ~w(canceling canceled)
    end

    test "is idempotent — cancelling an already-cancelled build returns 200" do
      user = create_user("bidem@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      number = create_build("acme", "p", bearer_for(user))
      path = "#{builds_path("acme", "p")}/#{number}/cancel"

      assert put_json(path, bearer: bearer_for(user)).status == 200
      conn2 = put_json(path, bearer: bearer_for(user))
      assert conn2.status == 200
      assert decode(conn2)["state"] in ~w(canceling canceled)
    end

    test "unknown build number in a member org → 404" do
      user = create_user("bcnf@harmont.dev")
      org = member_org("Acme", "acme", user)
      _pipeline = create_pipeline(org, "p")

      conn = put_json("#{builds_path("acme", "p")}/9999/cancel", bearer: bearer_for(user))
      assert conn.status == 404
    end

    test "non-member org → 404 (tenancy)" do
      member = create_user("bcowner@harmont.dev")
      org = member_org("Secret", "secret", member)
      _pipeline = create_pipeline(org, "p")
      number = create_build("secret", "p", bearer_for(member))

      outsider = create_user("bcoutsider@harmont.dev")

      conn =
        put_json("#{builds_path("secret", "p")}/#{number}/cancel", bearer: bearer_for(outsider))

      assert conn.status == 404

      # The build was NOT cancelled by the outsider's request.
      build = Repo.get_by!(Build, number: number)
      refute build.cancel_requested
    end
  end
end
