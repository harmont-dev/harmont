defmodule Harmont.Engine.ApiTest do
  @moduledoc """
  Tests for the in-process `Harmont.Engine.Api` entry point (Plan 4 bridge
  collapse). Oban runs in `:manual` mode so enqueued `CI.JobRunner`s do not
  auto-execute; we assert on what was enqueued with `assert_enqueued`.

  Each test starts from an EXISTING build row (the unification contract: the
  build is created once — here directly via the executor-origin changeset,
  mirroring `Harmont.Builds.create_build` on the API path — and `Exec.Api` only
  materialises its jobs+deps and starts it).
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  import Ecto.Query

  alias Harmont.Builds.{Build, Job, JobDep}
  alias Harmont.Engine.Api
  alias Harmont.Pipelines.RunnerToken
  alias Harmont.Repo

  @valid_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "steps" => [
                %{"type" => "command", "key" => "a", "cmd" => "echo a"},
                %{"type" => "wait"},
                %{"type" => "command", "key" => "b", "cmd" => "echo b", "builds_in" => "a"}
              ]
            })

  # Canonical graph-form IR emitted by hm / hm-pipeline-ir (petgraph-serde).
  @graph_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "graph" => %{
                "nodes" => [
                  %{
                    "step" => %{"key" => "base", "cmd" => "apt-get update", "label" => "base"},
                    "env" => %{"CI" => "true"}
                  },
                  %{
                    "step" => %{"key" => "build", "cmd" => "cargo build", "label" => "build"},
                    "env" => %{"CI" => "true"}
                  }
                ],
                "node_holes" => [],
                "edge_property" => "directed",
                "edges" => [[0, 1, "builds_in"]]
              }
            })

  defp existing_build do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "scheduled"})
      |> Repo.insert()

    build
  end

  describe "materialize_and_start/3" do
    test "materialises jobs+deps for the existing build, enqueues root runners, issues token" do
      build = existing_build()

      assert {:ok, {returned, raw}} =
               Api.materialize_and_start(build, @valid_ir, source_url: "http://x/source.tar.gz")

      # Same build row — no second row created.
      assert returned.id == build.id
      assert Repo.aggregate(Build, :count) == 1

      jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.state in ~w(pending scheduled)))

      deps = Repo.all(JobDep)
      assert length(deps) == 1

      # Exec fields set on the existing row.
      assert returned.source_url == "http://x/source.tar.gz"
      assert returned.default_image == "ubuntu:24.04"
      assert returned.runner_token_hash == :crypto.hash(:sha256, raw)

      # Root runner enqueued (Oban manual mode).
      assert_enqueued(worker: Harmont.Engine.CI.JobRunner)

      # Runner token issued + persisted (hashed).
      assert [%RunnerToken{} = token] = Repo.all(RunnerToken)
      assert token.build_id == build.id
      assert token.token_hash == Harmont.Token.hash(raw)
    end

    test "graph-form IR materialises jobs+deps identical to the steps-form path" do
      build = existing_build()

      assert {:ok, {returned, _raw}} =
               Api.materialize_and_start(build, @graph_ir,
                 source_url: "http://x/graph-source.tar.gz"
               )

      assert returned.id == build.id
      assert Repo.aggregate(Build, :count) == 1

      jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
      # Two nodes in the graph -> two jobs.
      assert length(jobs) == 2

      deps = Repo.all(JobDep)
      # One builds_in edge -> one dep row, carrying the builds_in kind.
      assert length(deps) == 1
      assert hd(deps).kind == "builds_in"

      assert returned.default_image == "ubuntu:24.04"
      assert_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end

    test "plan-rejected IR sets the build error fields, creates no jobs, returns {:error,{:plan_rejected,_}}" do
      build = existing_build()
      bad_ir = Jason.encode!(%{"version" => "1"})

      assert {:error, {:plan_rejected, detail}} = Api.materialize_and_start(build, bad_ir)
      assert is_binary(detail)

      reloaded = Repo.get!(Build, build.id)
      assert reloaded.state == "failed"
      assert reloaded.error_code == "bad_version"
      assert reloaded.error_message =~ "version"

      assert Repo.all(from(j in Job, where: j.build_id == ^build.id)) == []
      refute_enqueued(worker: Harmont.Engine.CI.JobRunner)
    end
  end

  describe "render_and_start/3" do
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

      Application.put_env(:harmont_engine, :render_backend, Harmont.CannedRenderBackend)
      :ok
    end

    test "renders IR via the fake VM backend then materialises + starts the build" do
      build = existing_build()

      # exec 1 = source fetch (no stdout), exec 2 = render (IR on stdout).
      Application.put_env(:harmont_engine, :canned_render_execs, [
        %{exit_code: 0, stdout: "", stderr: ""},
        %{exit_code: 0, stdout: @valid_ir, stderr: ""}
      ])

      assert {:ok, {returned, raw}} =
               Api.render_and_start(build, %{
                 slug: "ci",
                 source_url: "http://x/source.tar.gz",
                 source_sha256: ""
               })

      assert returned.id == build.id
      assert returned.source_url == "http://x/source.tar.gz"
      assert returned.runner_token_hash == :crypto.hash(:sha256, raw)

      jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
      assert length(jobs) == 2
      assert_enqueued(worker: Harmont.Engine.CI.JobRunner)

      # Token issued exactly once even though both render + start needed it.
      assert Repo.aggregate(RunnerToken, :count) == 1
    end

    test "render failure sets the build error fields and returns {:error,{:plan_rejected,_}}" do
      build = existing_build()

      Application.put_env(:harmont_engine, :canned_render_execs, [
        %{exit_code: 0, stdout: "", stderr: ""},
        %{exit_code: 2, stdout: "", stderr: "boom"}
      ])

      assert {:error, {:plan_rejected, detail}} =
               Api.render_and_start(build, %{
                 slug: "ci",
                 source_url: "http://x/source.tar.gz",
                 source_sha256: ""
               })

      assert detail =~ "boom"

      reloaded = Repo.get!(Build, build.id)
      assert reloaded.state == "failed"
      assert reloaded.error_code == "render_failed"
      assert Repo.all(from(j in Job, where: j.build_id == ^build.id)) == []
    end
  end

  describe "cancel/1" do
    test "delegates to Exec.Cancel.request/1 (true for existing, false for unknown)" do
      build = existing_build()
      assert Api.cancel(build.external_build_id) == true
      assert Api.cancel(Ecto.UUID.generate()) == false
    end
  end
end
