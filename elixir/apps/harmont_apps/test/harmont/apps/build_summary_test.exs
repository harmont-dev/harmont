defmodule Harmont.Apps.BuildSummaryTest do
  use Harmont.DataCase, async: true

  alias Harmont.Apps.BuildSummary
  alias Harmont.Apps.StepSummary
  alias Harmont.Builds
  alias Harmont.Builds.Job
  alias Harmont.Orgs
  alias Harmont.Pipelines
  alias Harmont.Repo

  defp seed_build_with_jobs do
    {:ok, org} =
      Orgs.create_org(%{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"}, Repo)

    {:ok, pipeline} =
      Pipelines.create_pipeline(
        org,
        %{
          slug: "ci",
          name: "CI",
          repository: "https://github.com/acme/widget.git",
          default_branch: "main"
        },
        Repo
      )

    {:ok, build} =
      Builds.create_build(
        pipeline,
        %{external_build_id: Ecto.UUID.generate(), source: "webhook"},
        Repo
      )

    insert_job = fn step, state, attrs ->
      %Job{}
      |> Job.changeset(
        Map.merge(
          %{build_id: build.id, step_key: step, name: step, command: "true", state: state},
          attrs
        )
      )
      |> Repo.insert!()
    end

    insert_job.("base", "passed", %{})
    insert_job.("clippy", "running", %{})
    insert_job.("pytest", "failed", %{exit_code: 1, error_message: "1 test failed"})

    build
  end

  test "maps the build's jobs to neutral StepSummary structs" do
    build = seed_build_with_jobs()
    steps = BuildSummary.for_build(build.external_build_id, Repo)
    assert length(steps) == 3

    assert %StepSummary{key: "pytest", state: "failed", exit_code: 1} =
             Enum.find(steps, &(&1.key == "pytest"))
  end

  test "returns [] for an unknown build uuid" do
    assert BuildSummary.for_build(Ecto.UUID.generate(), Repo) == []
  end

  test "returns [] for a non-UUID build id (e.g. a malformed/placeholder uuid)" do
    assert BuildSummary.for_build("not-a-uuid", Repo) == []
  end
end
