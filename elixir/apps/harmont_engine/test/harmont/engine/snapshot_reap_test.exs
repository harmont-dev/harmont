defmodule Harmont.Engine.SnapshotReapTest do
  use Harmont.DataCase, async: false
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Advance
  alias Harmont.Repo

  defmodule ReapBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_), do: {:ok, %{}}
    @impl true
    def exec(_, _), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def delete_snapshot(id) do
      send(:persistent_term.get({__MODULE__, :pid}), {:deleted, id})
      :ok
    end
  end

  setup do
    prev = Application.get_env(:harmont_vm, :backend)
    Application.put_env(:harmont_vm, :backend, ReapBackend)
    on_exit(fn -> Application.put_env(:harmont_vm, :backend, prev) end)
    :persistent_term.put({ReapBackend, :pid}, self())
    :ok
  end

  test "reap_snapshots/1 deletes every job snapshot for the build" do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "passed"})
      |> Repo.insert()

    {:ok, _} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "a",
        state: "passed",
        command: "true",
        snapshot_id: "snap-a"
      })
      |> Repo.insert()

    {:ok, _} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "b",
        state: "passed",
        command: "true",
        snapshot_id: nil
      })
      |> Repo.insert()

    Advance.reap_snapshots(build.id)

    assert_receive {:deleted, "snap-a"}, 1_000
    refute_received {:deleted, nil}
  end
end
