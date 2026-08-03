defmodule Harmont.Builds.JobTest do
  use Harmont.DataCase, async: true
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Repo

  test "insert a build with a job and read it back" do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "scheduled"})
      |> Repo.insert()

    {:ok, job} =
      %Job{}
      |> Job.changeset(%{build_id: build.id, step_key: "a", command: "echo a", state: "pending"})
      |> Repo.insert()

    assert Repo.get!(Job, job.id).step_key == "a"
  end

  test "job state must be a known value" do
    {:ok, build} =
      %Build{} |> Build.changeset(%{external_build_id: Ecto.UUID.generate()}) |> Repo.insert()

    cs = Job.changeset(%Job{}, %{build_id: build.id, step_key: "a", command: "x", state: "bogus"})
    refute cs.valid?
  end
end
