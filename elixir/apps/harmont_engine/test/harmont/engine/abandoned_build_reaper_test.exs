defmodule Harmont.Engine.AbandonedBuildReaperTest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.AbandonedBuildReaper
  alias Harmont.Engine.CI
  alias Harmont.Repo

  defmodule NoopBackend do
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
  end

  setup do
    prev = Application.get_env(:harmont_vm, :backend)
    Application.put_env(:harmont_vm, :backend, NoopBackend)
    on_exit(fn -> Application.put_env(:harmont_vm, :backend, prev) end)
    :ok
  end

  defp build(state, inserted_at) do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: state})
      |> Repo.insert()

    # Force inserted_at into the past (changeset timestamps are auto-set to now).
    Repo.update_all(from(x in Build, where: x.id == ^b.id), set: [inserted_at: inserted_at])
    Repo.get!(Build, b.id)
  end

  defp job(build, step_key, state) do
    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: build.id, step_key: step_key, state: state, command: "true"})
      |> Repo.insert()

    j
  end

  # An abandoned build: non-terminal ("running"), older than the deadline, with a
  # non-terminal job, no live Session, and no pending Oban job. Reaped by sweep/1.
  # Shared by the reap test and the telemetry test so there's one source of truth.
  @reaper_now ~U[2026-06-08 12:00:00Z]
  defp insert_abandoned_build_past_deadline do
    old = DateTime.add(@reaper_now, -7 * 3600, :second)
    b = build("running", old)
    job(b, "s1", "running")
    b
  end

  test "fails an old running build with no live session and no pending runner" do
    b = insert_abandoned_build_past_deadline()

    assert :ok = AbandonedBuildReaper.sweep(@reaper_now)

    assert Repo.get!(Build, b.id).state == "failed"
    assert Repo.get_by!(Job, build_id: b.id).state == "failed"
  end

  test "emits [:harmont, :abandoned_build, :reaped] telemetry when it reaps a build" do
    # An abandoned build: non-terminal, older than the deadline, no live Session,
    # no pending Oban job. (Reuse this file's existing abandoned-build setup.)
    build = insert_abandoned_build_past_deadline()

    handler = {:reaper_telemetry, self()}

    :telemetry.attach(
      handler,
      [:harmont, :abandoned_build, :reaped],
      fn event, measurements, metadata, _ ->
        send(self(), {:reaped, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok = AbandonedBuildReaper.sweep(@reaper_now)

    assert_received {:reaped, [:harmont, :abandoned_build, :reaped], %{count: count},
                     %{build_id: build_id}}

    assert build_id == build.id
    assert count >= 1
  end

  test "leaves a young build alone" do
    now = ~U[2026-06-08 12:00:00Z]
    recent = DateTime.add(now, -10 * 60, :second)
    b = build("running", recent)
    job(b, "s1", "running")

    assert :ok = AbandonedBuildReaper.sweep(now)
    assert Repo.get!(Build, b.id).state == "running"
  end

  test "leaves a build with a live session alone" do
    now = ~U[2026-06-08 12:00:00Z]
    old = DateTime.add(now, -7 * 3600, :second)
    b = build("running", old)
    j = job(b, "s1", "running")

    {:ok, _} = Registry.register(Harmont.Engine.SessionRegistry, j.id, :live)
    assert :ok = AbandonedBuildReaper.sweep(now)
    assert Repo.get!(Build, b.id).state == "running"
  end

  test "leaves a build with a pending Oban runner alone" do
    now = ~U[2026-06-08 12:00:00Z]
    old = DateTime.add(now, -7 * 3600, :second)
    b = build("running", old)
    j = job(b, "s1", "running")

    # A scheduled CI runner referencing this build keeps it protected.
    {:ok, _} =
      j
      |> CI.runner_changeset(nil)
      |> Oban.insert()

    assert :ok = AbandonedBuildReaper.sweep(now)
    assert Repo.get!(Build, b.id).state == "running"
  end

  test "is registered as a quarter-hourly cron on the maintenance queue" do
    oban = Application.fetch_env!(:harmont_core, Oban)
    plugins = Keyword.fetch!(oban, :plugins)

    {Oban.Pro.Plugins.DynamicCron, dc} =
      Enum.find(plugins, &match?({Oban.Pro.Plugins.DynamicCron, _}, &1))

    assert Enum.any?(dc[:crontab], fn
             {"*/15 * * * *", Harmont.Engine.AbandonedBuildReaper, _opts} -> true
             _ -> false
           end)
  end
end
