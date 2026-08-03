defmodule HarmontApi.SourceTest do
  @moduledoc """
  Tests for the internal source-archive serving endpoint.

  `GET /api/v0/internal/builds/:build_uuid/source.tar.gz` serves a build's
  uploaded source tarball to the in-VM sandbox/agent. It is authenticated with
  the build's RUNNER TOKEN (NOT a session bearer): the raw token arrives as
  `Authorization: Bearer <runner_token>` and is validated against the build's
  stored `runner_token_hash` — which is the RAW BINARY `:crypto.hash(:sha256,
  raw)`, exactly the way `Harmont.Engine.Materialize.materialize_jobs/3` sets it
  and `HarmontWeb.AgentSocket` validates it (NOT the hex `Harmont.Token.hash/1`
  used by the runner_tokens table). Validation is non-consuming.

  These run for real against Postgres + the filesystem-backed Local storage
  adapter (config/test.exs).
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Builds
  alias Harmont.Builds.Build
  alias Harmont.Orgs
  alias Harmont.Pipelines
  alias Harmont.Pipelines.RunnerTokens
  alias Harmont.Storage

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # Seed a build set up the way `materialize_jobs` leaves it: a runner token is
  # issued (into the runner_tokens table, hex-hashed) AND the build's
  # `runner_token_hash` is set to the RAW-BINARY sha256 of the same raw token.
  # Returns {build, raw_runner_token}.
  defp seed_build do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-#{uniq()}"}, Repo)

    {:ok, pipeline} =
      Pipelines.create_pipeline(
        org,
        %{
          name: "p",
          slug: "p-#{uniq()}",
          repository: "github.com/acme/r",
          default_branch: "main"
        },
        Repo
      )

    {:ok, build} = Builds.create_build(pipeline, %{source: "api", branch: "main"}, Repo)

    {:ok, {raw, _token}} = RunnerTokens.issue(build.id, DateTime.utc_now(), Repo)

    {:ok, build} =
      build
      |> Build.changeset(%{runner_token_hash: :crypto.hash(:sha256, raw)})
      |> Repo.update()

    {build, raw}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp put_source(build, bytes) do
    {:ok, _} = Storage.put(Storage.source_key(build.external_build_id), bytes)
    :ok
  end

  defp source_path(build), do: "/api/v0/internal/builds/#{build.external_build_id}/source.tar.gz"

  defp get_source(path, token) do
    conn =
      :get
      |> Plug.Test.conn(path, "")
      |> Plug.Conn.fetch_query_params()

    conn =
      case token do
        nil -> conn
        t -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> t)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "GET …/internal/builds/:build_uuid/source.tar.gz" do
    test "valid runner token → 200 + the stored bytes" do
      {build, raw} = seed_build()
      bytes = :crypto.strong_rand_bytes(512)
      :ok = put_source(build, bytes)

      conn = get_source(source_path(build), raw)

      assert conn.status == 200
      assert conn.resp_body == bytes
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/gzip"]
    end

    test "wrong token → 401" do
      {build, _raw} = seed_build()
      :ok = put_source(build, "data")

      conn = get_source(source_path(build), "definitely-not-the-token")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "unauthorized"
    end

    test "missing token → 401" do
      {build, _raw} = seed_build()
      :ok = put_source(build, "data")

      conn = get_source(source_path(build), nil)

      assert conn.status == 401
    end

    test "valid token but missing object → 404" do
      {build, raw} = seed_build()

      conn = get_source(source_path(build), raw)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "source_not_found"
    end

    test "unknown build → 404" do
      {_build, raw} = seed_build()
      unknown = Ecto.UUID.generate()

      conn = get_source("/api/v0/internal/builds/#{unknown}/source.tar.gz", raw)

      assert conn.status == 404
    end

    test "the source endpoint does NOT consume the runner token (re-fetchable)" do
      {build, raw} = seed_build()
      :ok = put_source(build, "twice")

      assert get_source(source_path(build), raw).status == 200
      # A second fetch with the same token still succeeds — non-consuming.
      assert get_source(source_path(build), raw).status == 200
    end
  end
end
