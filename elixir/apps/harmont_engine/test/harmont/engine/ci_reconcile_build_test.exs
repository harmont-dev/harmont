defmodule Harmont.Engine.CIReconcileBuildTest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.Build
  alias Harmont.Engine.{CI, MaterializeFixture}
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  setup do
    # start_build enqueues runners whose Sessions spawn under the
    # DynamicSupervisor; share the sandbox connection so they see this tx.
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Materialise a single-command graph (one pending root job, no prereqs) onto a
  # fresh build, stamping the requested `timeout_ms`.
  defp seed_build_with_root(opts) do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [%CommandStep{key: "a", cmd: "true"}]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    build
    |> Build.changeset(%{timeout_ms: Keyword.get(opts, :timeout_ms)})
    |> Repo.update!()
  end

  test "start_build/2 enqueues a ReconcileBuild at the pipeline deadline" do
    build = seed_build_with_root(timeout_ms: 600_000)
    :ok = CI.start_build(build.id, "tok")

    assert_enqueued(worker: Harmont.Engine.CI.ReconcileBuild, meta: %{"build_id" => build.id})
  end

  test "start_build/2 does NOT enqueue ReconcileBuild when timeout_ms is nil" do
    build = seed_build_with_root(timeout_ms: nil)
    :ok = CI.start_build(build.id, "tok")

    refute_enqueued(worker: Harmont.Engine.CI.ReconcileBuild)
  end
end
