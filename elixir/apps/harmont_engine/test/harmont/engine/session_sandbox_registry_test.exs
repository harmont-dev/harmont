defmodule Harmont.Engine.SessionSandboxRegistryTest do
  use Harmont.DataCase, async: false

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Session
  alias Harmont.Repo
  alias Harmont.Sandboxes
  alias Harmont.Sandboxes.Sandbox

  # A backend that reports a handle id and is a live-VM fork source, so the
  # session records `daytona`-shaped rows and keeps fork parents alive.
  defmodule Daytona do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_), do: {:ok, %{sandbox_id: "sb-live"}}
    @impl true
    def exec(_, _), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def snapshot(%{sandbox_id: id}), do: {:ok, id}
    @impl true
    def delete_snapshot(_), do: :ok
    @impl true
    def fork_source_is_live_vm?, do: true
    @impl true
    def handle_id(%{sandbox_id: id}), do: id
  end

  setup do
    prev = Application.get_env(:harmont_vm, :backend)
    Application.put_env(:harmont_vm, :backend, Daytona)
    on_exit(fn -> Application.put_env(:harmont_vm, :backend, prev) end)
    :ok
  end

  defp build_job(job_state) do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "running"})
      |> Repo.insert()

    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "s1", state: job_state, command: "true"})
      |> Repo.insert()

    {b, j}
  end

  test "record_sandbox/3 inserts an active job row keyed by handle id" do
    {b, j} = build_job("assigned")
    data = %{job_id: j.id, build_id: b.id, backend: Daytona}

    assert :ok = Session.record_sandbox(j, data, %{sandbox_id: "sb-live"})

    s = Repo.get_by!(Sandbox, provider: "daytona", external_id: "sb-live")
    assert s.state == "active"
    assert s.kind == "job"
    assert s.job_id == j.id
    assert s.build_id == b.id
  end

  test "release_sandbox/3 marks deleted when not a fork source" do
    {b, j} = build_job("failed")

    {:ok, _} =
      Sandboxes.record(%{
        provider: "daytona",
        external_id: "sb-live",
        kind: "job",
        build_id: b.id
      })

    data = %{job_id: j.id, build_id: b.id, backend: Daytona}

    # job with no builds_in dependents -> not a fork source -> deleted
    assert :ok = Session.release_sandbox(j, data, %{sandbox_id: "sb-live"})
    assert Repo.get_by!(Sandbox, external_id: "sb-live").state == "deleted"
  end

  test "release_sandbox/3 keeps fork parent active and marks kind fork_parent" do
    {b, parent} = build_job("passed")
    # A sibling that builds_in the parent makes the parent a live fork source.
    {:ok, _} =
      %Job{}
      |> Job.changeset(%{
        build_id: b.id,
        step_key: "child",
        state: "pending",
        command: "true",
        builds_in: "s1"
      })
      |> Repo.insert()

    {:ok, _} =
      Sandboxes.record(%{
        provider: "daytona",
        external_id: "sb-live",
        kind: "job",
        build_id: b.id
      })

    data = %{job_id: parent.id, build_id: b.id, backend: Daytona}

    assert :ok = Session.release_sandbox(parent, data, %{sandbox_id: "sb-live"})
    s = Repo.get_by!(Sandbox, external_id: "sb-live")
    assert s.state == "active"
    assert s.kind == "fork_parent"
  end
end
