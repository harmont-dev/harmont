defmodule Harmont.Engine.AdvanceReapRegistryTest do
  use Harmont.DataCase, async: false

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Advance
  alias Harmont.Repo
  alias Harmont.Sandboxes
  alias Harmont.Sandboxes.Sandbox

  defmodule FakeBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_), do: {:ok, %{}}
    @impl true
    def exec(_, _), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def delete_snapshot(_), do: :ok
    @impl true
    def fork_source_is_live_vm?, do: true
    @impl true
    def handle_id(%{sandbox_id: id}), do: id
  end

  setup do
    prev = Application.get_env(:harmont_vm, :backend)
    Application.put_env(:harmont_vm, :backend, FakeBackend)
    prev_iv = Application.get_env(:harmont_vm, :reap_pass_interval_ms)
    Application.put_env(:harmont_vm, :reap_pass_interval_ms, 0)

    on_exit(fn ->
      Application.put_env(:harmont_vm, :backend, prev)
      Application.put_env(:harmont_vm, :reap_pass_interval_ms, prev_iv)
    end)

    :ok
  end

  test "reap_snapshots/1 marks the build's sandbox registry rows deleted" do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "passed"})
      |> Repo.insert()

    {:ok, _j} =
      %Job{}
      |> Job.changeset(%{
        build_id: b.id,
        step_key: "s1",
        state: "passed",
        command: "true",
        snapshot_id: "sb-parent"
      })
      |> Repo.insert()

    {:ok, _} =
      Sandboxes.record(%{
        provider: "fake_backend",
        external_id: "sb-parent",
        kind: "fork_parent",
        build_id: b.id
      })

    assert :ok = Advance.reap_snapshots(b.id)
    assert Repo.get_by!(Sandbox, external_id: "sb-parent").state == "deleted"
  end
end
