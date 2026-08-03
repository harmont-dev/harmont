defmodule Harmont.Engine.ReapForkTreeTest do
  use Harmont.DataCase, async: false
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Advance
  alias Harmont.Repo

  # A live-VM fork backend (mirrors Daytona): `fork_source_is_live_vm?/0` is true,
  # so reap_snapshots must sweep the fork tree over MULTIPLE passes. Each
  # delete_snapshot call is forwarded to the test pid so it can count passes.
  defmodule FakeLiveBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_), do: {:ok, %{}}
    @impl true
    def exec(_, _), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def fork_source_is_live_vm?, do: true
    @impl true
    def delete_snapshot(id) do
      send(:persistent_term.get({__MODULE__, :pid}), {:deleted, id})
      :ok
    end
  end

  setup do
    prev_backend = Application.get_env(:harmont_vm, :backend)
    prev_interval = Application.get_env(:harmont_vm, :reap_pass_interval_ms)
    Application.put_env(:harmont_vm, :backend, FakeLiveBackend)
    Application.put_env(:harmont_vm, :reap_pass_interval_ms, 1)

    on_exit(fn ->
      Application.put_env(:harmont_vm, :backend, prev_backend)
      Application.put_env(:harmont_vm, :reap_pass_interval_ms, prev_interval)
    end)

    :persistent_term.put({FakeLiveBackend, :pid}, self())
    :ok
  end

  test "reap_snapshots/1 sweeps a live-VM fork tree over MULTIPLE passes per id" do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "passed"})
      |> Repo.insert()

    for {key, sid} <- [{"a", "snap-a"}, {"b", "snap-b"}] do
      {:ok, _} =
        %Job{}
        |> Job.changeset(%{
          build_id: build.id,
          step_key: key,
          state: "passed",
          command: "true",
          snapshot_id: sid
        })
        |> Repo.insert()
    end

    Advance.reap_snapshots(build.id)

    # Drain every delete forwarded to us and count per id.
    counts = drain_counts(%{})

    assert counts["snap-a"] > 1, "expected snap-a deleted more than once, got #{counts["snap-a"]}"
    assert counts["snap-b"] > 1, "expected snap-b deleted more than once, got #{counts["snap-b"]}"
  end

  defp drain_counts(acc) do
    receive do
      {:deleted, id} -> drain_counts(Map.update(acc, id, 1, &(&1 + 1)))
    after
      200 -> acc
    end
  end
end
