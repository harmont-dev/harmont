defmodule Harmont.Engine.SandboxReaperTest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Engine.SandboxReaper
  alias Harmont.Repo
  alias Harmont.Sandboxes
  alias Harmont.Sandboxes.Sandbox

  # Live-VM fork backend. list_managed_sandboxes + delete_snapshot driven from
  # :persistent_term; deletes are messaged to the test pid.
  defmodule LiveBackend do
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

    @impl true
    def list_managed_sandboxes, do: :persistent_term.get({__MODULE__, :list})
  end

  setup do
    prev = Application.get_env(:harmont_vm, :backend)
    Application.put_env(:harmont_vm, :backend, LiveBackend)
    prev_cfg = Application.get_env(:harmont_vm, HarmontVm.Backend.Daytona)
    # The reaper reads the current snapshot name from Daytona config.
    Application.put_env(:harmont_vm, HarmontVm.Backend.Daytona, snapshot: "snap-current")

    on_exit(fn ->
      Application.put_env(:harmont_vm, :backend, prev)
      Application.put_env(:harmont_vm, HarmontVm.Backend.Daytona, prev_cfg)
    end)

    :persistent_term.put({LiveBackend, :pid}, self())
    :ok
  end

  defp build(state) do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: state})
      |> Repo.insert()

    b
  end

  test "live-VM branch reaps orphans, terminal-build sandboxes, stale templates; keeps live + current template + young" do
    live_b = build("running")
    term_b = build("failed")

    {:ok, _} =
      Sandboxes.record(%{
        provider: "live_backend",
        external_id: "sb-live",
        kind: "job",
        build_id: live_b.id
      })

    {:ok, _} =
      Sandboxes.record(%{
        provider: "live_backend",
        external_id: "sb-term",
        kind: "fork_parent",
        build_id: term_b.id
      })

    # A registry row whose provider sandbox vanished -> should be reconciled to deleted.
    {:ok, _} =
      Sandboxes.record(%{
        provider: "live_backend",
        external_id: "sb-gone",
        kind: "job",
        build_id: live_b.id
      })

    now = ~U[2026-06-08 12:00:00Z]
    old = DateTime.to_unix(DateTime.add(now, -60 * 60, :second), :millisecond)
    fresh = DateTime.to_unix(DateTime.add(now, -5 * 60, :second), :millisecond)

    :persistent_term.put(
      {LiveBackend, :list},
      {:ok,
       [
         %{id: "sb-live", kind: :job, snapshot_label: nil, create_time_ms: old},
         %{id: "sb-term", kind: :job, snapshot_label: nil, create_time_ms: old},
         %{id: "sb-orphan-old", kind: :job, snapshot_label: nil, create_time_ms: old},
         %{id: "sb-orphan-young", kind: :job, snapshot_label: nil, create_time_ms: fresh},
         %{
           id: "tmpl-current",
           kind: :template,
           snapshot_label: "snap-current",
           create_time_ms: old
         },
         %{id: "tmpl-stale", kind: :template, snapshot_label: "snap-old", create_time_ms: old}
       ]}
    )

    assert :ok = SandboxReaper.sweep(LiveBackend, now)

    assert_receive {:deleted, "sb-term"}, 500
    assert_receive {:deleted, "sb-orphan-old"}, 500
    assert_receive {:deleted, "tmpl-stale"}, 500
    refute_receive {:deleted, "sb-live"}, 100
    refute_receive {:deleted, "sb-orphan-young"}, 100
    refute_receive {:deleted, "tmpl-current"}, 100

    # Registry reconciliation: sb-term deleted (reaped), sb-gone reconciled away.
    assert Repo.get_by!(Sandbox, external_id: "sb-term").state == "deleted"
    assert Repo.get_by!(Sandbox, external_id: "sb-gone").state == "deleted"
    assert Repo.get_by!(Sandbox, external_id: "sb-live").state == "active"
  end

  test "never deletes a non-terminal build's snapshot_id even when its registry row was lost" do
    # A live fork parent whose best-effort registry write was dropped: it is NOT
    # in the registry, but a running build still forks it (durable snapshot_id).
    running = build("running")

    {:ok, _} =
      %Job{}
      |> Job.changeset(%{
        build_id: running.id,
        step_key: "parent",
        state: "passed",
        command: "true",
        snapshot_id: "sb-inuse-orphan"
      })
      |> Repo.insert()

    now = ~U[2026-06-08 12:00:00Z]
    old = DateTime.to_unix(DateTime.add(now, -60 * 60, :second), :millisecond)

    :persistent_term.put(
      {LiveBackend, :list},
      {:ok, [%{id: "sb-inuse-orphan", kind: :job, snapshot_label: nil, create_time_ms: old}]}
    )

    assert :ok = SandboxReaper.sweep(LiveBackend, now)
    refute_receive {:deleted, "sb-inuse-orphan"}, 100
  end

  test "perform/1 runs a sweep against the configured backend" do
    term_b = build("failed")

    {:ok, _} =
      Sandboxes.record(%{
        provider: "live_backend",
        external_id: "sb-x",
        kind: "job",
        build_id: term_b.id
      })

    :persistent_term.put(
      {LiveBackend, :list},
      {:ok, [%{id: "sb-x", kind: :job, snapshot_label: nil, create_time_ms: 0}]}
    )

    assert :ok = perform_job(SandboxReaper, %{})
    assert_receive {:deleted, "sb-x"}, 500
  end

  test "reaps error/build_failed sandboxes immediately, even when young, and keeps healthy young ones" do
    now = ~U[2026-06-08 12:00:00Z]
    fresh = DateTime.to_unix(DateTime.add(now, -5 * 60, :second), :millisecond)

    :persistent_term.put(
      {LiveBackend, :list},
      {:ok,
       [
         %{
           id: "sb-error-young",
           kind: :job,
           snapshot_label: nil,
           create_time_ms: fresh,
           state: "error"
         },
         %{
           id: "sb-failed-young",
           kind: :job,
           snapshot_label: nil,
           create_time_ms: fresh,
           state: "build_failed"
         },
         %{
           id: "sb-started-young",
           kind: :job,
           snapshot_label: nil,
           create_time_ms: fresh,
           state: "started"
         },
         %{id: "sb-legacy-young", kind: :job, snapshot_label: nil, create_time_ms: fresh}
       ]}
    )

    assert :ok = SandboxReaper.sweep(LiveBackend, now)

    assert_receive {:deleted, "sb-error-young"}, 500
    assert_receive {:deleted, "sb-failed-young"}, 500
    refute_receive {:deleted, "sb-started-young"}, 100
    refute_receive {:deleted, "sb-legacy-young"}, 100
  end

  test "is registered as an hourly cron on the maintenance queue" do
    oban = Application.fetch_env!(:harmont_core, Oban)
    plugins = Keyword.fetch!(oban, :plugins)

    {Oban.Pro.Plugins.DynamicCron, dc} =
      Enum.find(plugins, &match?({Oban.Pro.Plugins.DynamicCron, _}, &1))

    assert Enum.any?(dc[:crontab], fn
             {"0 * * * *", Harmont.Engine.SandboxReaper, _opts} -> true
             _ -> false
           end)
  end

  test "enqueue_boot_sweep/0 enqueues a SandboxReaper job on the maintenance queue" do
    assert {:ok, %Oban.Job{}} = SandboxReaper.enqueue_boot_sweep()
    assert_enqueued(worker: SandboxReaper, queue: :maintenance)
  end
end
