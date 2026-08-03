defmodule Harmont.Logs.AuthzTest do
  use Harmont.DataCase, async: true
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Logs.Authz
  alias Harmont.Repo

  setup do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate()})
      |> Repo.insert()

    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "a", command: "x", state: "running"})
      |> Repo.insert()

    %{build: b, job: j}
  end

  test "returns true when the job belongs to the build", %{build: b, job: j} do
    assert Authz.authorized?(j.id, b.external_build_id) == true
  end

  test "returns false when the build_uuid does not own the job", %{job: j} do
    assert Authz.authorized?(j.id, Ecto.UUID.generate()) == false
  end

  test "returns false for a non-UUID job_id", %{build: b} do
    assert Authz.authorized?("not-a-uuid", b.external_build_id) == false
  end

  test "returns false for a nil build_uuid", %{job: j} do
    assert Authz.authorized?(j.id, nil) == false
  end

  test "returns false for a non-binary build_uuid", %{job: j} do
    assert Authz.authorized?(j.id, 123) == false
  end
end
