defmodule Harmont.Engine.CISnapshotTest do
  use Harmont.DataCase, async: false
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.CI
  alias Harmont.Repo

  test "parent_snapshot_id/1 returns the builds_in parent's snapshot_id" do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "running"})
      |> Repo.insert()

    {:ok, _parent} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "base",
        state: "passed",
        command: "true",
        snapshot_id: "snap-base-1"
      })
      |> Repo.insert()

    {:ok, child} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "rustup",
        state: "scheduled",
        command: "true",
        builds_in: "base"
      })
      |> Repo.insert()

    {:ok, root} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "base2",
        state: "scheduled",
        command: "true"
      })
      |> Repo.insert()

    assert CI.parent_snapshot_id(child) == "snap-base-1"
    assert CI.parent_snapshot_id(root) == nil
  end
end
