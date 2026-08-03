defmodule Harmont.SandboxesTest do
  use Harmont.DataCase, async: true

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Repo
  alias Harmont.Sandboxes
  alias Harmont.Sandboxes.Sandbox

  defp build(state) do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: state})
      |> Repo.insert()

    b
  end

  defp job(build) do
    {:ok, j} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "s#{System.unique_integer([:positive])}",
        state: "running",
        command: "true"
      })
      |> Repo.insert()

    j
  end

  test "record/1 inserts an active row" do
    b = build("running")
    j = job(b)

    {:ok, s} =
      Sandboxes.record(%{
        provider: "daytona",
        external_id: "sb-1",
        kind: "job",
        job_id: j.id,
        build_id: b.id
      })

    assert s.state == "active"
    assert s.kind == "job"
  end

  test "record/1 is idempotent on (provider, external_id) and re-activates" do
    b = build("running")
    {:ok, s1} = Sandboxes.record(%{provider: "daytona", external_id: "sb-2", kind: "render"})
    Sandboxes.mark_deleted("daytona", "sb-2")
    {:ok, s2} = Sandboxes.record(%{provider: "daytona", external_id: "sb-2", kind: "render"})

    assert s1.id == s2.id
    assert Repo.get!(Sandbox, s2.id).state == "active"
    assert Repo.aggregate(Sandbox, :count) == 1
    _ = b
  end

  test "mark_deleted/2 flips state to deleted; no-op when absent" do
    {:ok, _} = Sandboxes.record(%{provider: "daytona", external_id: "sb-3", kind: "job"})
    assert :ok = Sandboxes.mark_deleted("daytona", "sb-3")
    assert Repo.get_by!(Sandbox, external_id: "sb-3").state == "deleted"
    assert :ok = Sandboxes.mark_deleted("daytona", "does-not-exist")
  end

  test "mark_fork_parent/2 sets kind" do
    {:ok, _} = Sandboxes.record(%{provider: "daytona", external_id: "sb-4", kind: "job"})
    assert :ok = Sandboxes.mark_fork_parent("daytona", "sb-4")
    assert Repo.get_by!(Sandbox, external_id: "sb-4").kind == "fork_parent"
  end

  test "active_with_build_state/1 returns active rows with their build's state" do
    term = build("failed")
    live = build("running")

    {:ok, _} =
      Sandboxes.record(%{
        provider: "daytona",
        external_id: "sb-term",
        kind: "fork_parent",
        build_id: term.id
      })

    {:ok, _} =
      Sandboxes.record(%{
        provider: "daytona",
        external_id: "sb-live",
        kind: "job",
        build_id: live.id
      })

    {:ok, _} = Sandboxes.record(%{provider: "daytona", external_id: "sb-render", kind: "render"})
    {:ok, _} = Sandboxes.record(%{provider: "runloop", external_id: "sb-other", kind: "job"})
    Sandboxes.mark_deleted("daytona", "sb-term-deleted")

    rows = Sandboxes.active_with_build_state("daytona")
    by_id = Map.new(rows, &{&1.external_id, &1})

    assert by_id["sb-term"].build_state == "failed"
    assert by_id["sb-live"].build_state == "running"
    assert by_id["sb-render"].build_state == nil
    refute Map.has_key?(by_id, "sb-other")
    assert map_size(by_id) == 3
  end
end
