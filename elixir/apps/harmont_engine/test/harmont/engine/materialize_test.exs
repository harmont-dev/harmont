defmodule Harmont.Engine.MaterializeTest do
  use Harmont.DataCase, async: true
  alias Harmont.Builds.{Job, JobDep}
  alias Harmont.Engine.MaterializeFixture
  alias Harmont.Repo
  alias HarmontIr.{Flat, Planner}
  import Ecto.Query

  defp graph do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %HarmontIr.CommandStep{key: "a", cmd: "echo a"},
          {:wait, false},
          %HarmontIr.CommandStep{key: "b", cmd: "echo b", builds_in: "a"}
        ]
      })

    g
  end

  test "creates a build, one job per node, one dep per edge" do
    ext = Ecto.UUID.generate()

    assert {:ok, build} =
             MaterializeFixture.run(graph(),
               external_build_id: ext,
               source_url: "http://x",
               runner_token: "tok"
             )

    jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
    assert length(jobs) == 2
    assert Enum.all?(jobs, &(&1.state == "pending"))

    deps = Repo.all(JobDep)
    assert length(deps) == 1
    [dep] = deps
    b = Enum.find(jobs, &(&1.step_key == "b"))
    a = Enum.find(jobs, &(&1.step_key == "a"))
    assert dep.dependent_id == b.id and dep.prerequisite_id == a.id and dep.kind == "builds_in"
    assert build.runner_token_hash == :crypto.hash(:sha256, "tok")
  end

  test "maps each step's IR label to the job name; labelless steps stay nil" do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %HarmontIr.CommandStep{key: "build", cmd: "make", label: "Build the app"},
          %HarmontIr.CommandStep{key: "test", cmd: "make test"}
        ]
      })

    assert {:ok, build} =
             MaterializeFixture.run(g,
               external_build_id: Ecto.UUID.generate(),
               runner_token: "tok"
             )

    jobs = Repo.all(from(j in Job, where: j.build_id == ^build.id))
    build_job = Enum.find(jobs, &(&1.step_key == "build"))
    test_job = Enum.find(jobs, &(&1.step_key == "test"))

    assert build_job.name == "Build the app"
    assert is_nil(test_job.name)
  end

  test "materialize_jobs/3 copies the graph pipeline timeout onto the build (ms)" do
    graph =
      HarmontIr.Graph.new(nil, 1800)
      |> HarmontIr.Graph.add_node(%HarmontIr.Transition{
        step: %HarmontIr.CommandStep{key: "a", cmd: "echo a"},
        env: %{}
      })

    assert {:ok, build} =
             MaterializeFixture.run(graph,
               external_build_id: Ecto.UUID.generate(),
               runner_token: "tok"
             )

    assert build.timeout_ms == 1_800_000
  end

  test "materialize_jobs/3 leaves build.timeout_ms nil when the graph has no pipeline timeout" do
    graph =
      HarmontIr.Graph.new(nil)
      |> HarmontIr.Graph.add_node(%HarmontIr.Transition{
        step: %HarmontIr.CommandStep{key: "a", cmd: "echo a"},
        env: %{}
      })

    assert {:ok, build} =
             MaterializeFixture.run(graph,
               external_build_id: Ecto.UUID.generate(),
               runner_token: "tok"
             )

    assert is_nil(build.timeout_ms)
  end
end
