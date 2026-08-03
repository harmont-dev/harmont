defmodule Harmont.Engine.SessionTest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.Job
  alias Harmont.Engine.{MaterializeFixture, Session, SessionSupervisor}
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp single_job_build(cmd) do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [%CommandStep{key: "only", cmd: cmd}]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    build
  end

  defp the_job(build), do: Repo.one!(from(j in Job, where: j.build_id == ^build.id))

  # A 2-node build where `leaf` builds_in `base`, so `base` is a snapshot parent.
  # Returns {build, base_job}.
  defp builds_in_chain_build do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %CommandStep{key: "base", cmd: "true"},
          %CommandStep{key: "leaf", cmd: "true", builds_in: "base"}
        ]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    base = Repo.one!(from(j in Job, where: j.build_id == ^build.id and j.step_key == "base"))
    {build, base}
  end

  defp wait_for_state(job_id, target, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      if Repo.get!(Job, job_id).state == target,
        do: {:halt, :ok},
        else:
          (
            Process.sleep(20)
            {:cont, nil}
          )
    end)
  end

  test "Local-mode Session drives a scheduled job to passed (exit 0)" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false
             )

    assert :ok == wait_for_state(job.id, "passed")
    assert Repo.get!(Job, job.id).exit_code == 0
  end

  test "Local-mode Session persists the VM handle on the job" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false
             )

    assert :ok == wait_for_state(job.id, "passed")
    # The Local backend's handle is %{dir, name} with name == job.id, and its
    # handle_id/1 returns that name, so vm_handle ends up equal to the job id.
    assert Repo.get!(Job, job.id).vm_handle == job.id
  end

  test "Local-mode Session drives a failing command to failed (nonzero exit)" do
    build = single_job_build("exit 7")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false
             )

    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).exit_code == 7
  end

  defmodule FailingBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:error, {:provision_failed, :boom}}
    @impl true
    def exec(_h, _o), do: {:error, :unreachable}
    @impl true
    def teardown(_h), do: :ok
  end

  test "provision failure drives the job to failed (regression: was stuck scheduled)" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false,
               backend: FailingBackend
             )

    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).error_code == "provision_failed"
    assert Repo.get!(Job, job.id).vm_handle == nil
  end

  test "start_session is idempotent for the same job_id" do
    build = single_job_build("sleep 0.2")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    opts = [job_id: job.id, build_id: build.id, token: "tok", use_agent: false]
    assert :ok == SessionSupervisor.start_session(opts)
    # second start while the first is alive -> already_started, treated as :ok
    assert :ok == SessionSupervisor.start_session(opts)

    assert :ok == wait_for_state(job.id, "passed")
  end

  # --- counting backend: tracks provision/exec; provision can be made to block --

  defmodule CountingBackend do
    @behaviour HarmontVm.Backend

    def start_table do
      _ =
        if :ets.whereis(:session_test_counters) != :undefined,
          do: :ets.delete(:session_test_counters)

      :ets.new(:session_test_counters, [:public, :named_table, :set])
      :ets.insert(:session_test_counters, {:provision, 0})
      :ok
    end

    def provisions, do: :ets.lookup_element(:session_test_counters, :provision, 2)

    @impl true
    def provision(_spec) do
      _ = :ets.update_counter(:session_test_counters, :provision, 1)
      {:ok, %{vm: "counting-vm"}}
    end

    @impl true
    def exec(_h, _o), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def teardown(_h), do: :ok
  end

  # A backend whose exec never returns (agent-mode launch ignores it anyway).
  defmodule SilentAgentBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "silent"}}
    @impl true
    def exec(_h, _o), do: Process.sleep(:infinity)
    @impl true
    def teardown(_h), do: :ok
  end

  # Captures the bootstrap script exec'd into the VM and forwards it to the test
  # pid (stashed in :persistent_term before the session starts).
  defmodule CapturingAgentBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "capture"}}
    @impl true
    def exec(_h, %{command: cmd}) do
      send(:persistent_term.get({__MODULE__, :pid}), {:agent_script, cmd})
      Process.sleep(:infinity)
    end

    @impl true
    def teardown(_h), do: :ok
  end

  # Records the provision spec so a test can assert parent_snapshot threading.
  defmodule SpecRecordingBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(spec) do
      send(:persistent_term.get({__MODULE__, :pid}), {:provision_spec, spec})
      {:ok, %{vm: "rec"}}
    end

    @impl true
    def exec(_h, _o), do: Process.sleep(:infinity)
    @impl true
    def snapshot(_h), do: {:ok, "snap-unused"}
    @impl true
    def teardown(_h), do: :ok
  end

  # Snapshots to a fixed id and reports snapshot/teardown calls to the test.
  defmodule SnapshotBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "snap"}}
    @impl true
    def exec(_h, _o), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def snapshot(_h) do
      send(:persistent_term.get({__MODULE__, :pid}), :snapshot_called)
      {:ok, "snap-fixed-1"}
    end

    @impl true
    def teardown(_h) do
      send(:persistent_term.get({__MODULE__, :pid}), :teardown_called)
      :ok
    end
  end

  # snapshot/1 reads the job's CURRENT persisted state and reports it, so a test
  # can assert the snapshot is taken BEFORE the `passed` write (the race-closing
  # invariant). Job id + test pid are stashed in :persistent_term.
  defmodule StateProbeSnapshotBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "probe"}}
    @impl true
    def exec(_h, _o), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def snapshot(_h) do
      {pid, job_id} = :persistent_term.get({__MODULE__, :ctx})
      send(pid, {:snapshot_at_state, Harmont.Repo.get!(Harmont.Builds.Job, job_id).state})
      {:ok, "snap-probe"}
    end

    @impl true
    def teardown(_h), do: :ok
  end

  # snapshot/1 always fails, to exercise the snapshot_failed terminal path.
  defmodule FailingSnapshotBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "fail"}}
    @impl true
    def exec(_h, _o), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def snapshot(_h), do: {:error, :boom}
    @impl true
    def teardown(_h), do: :ok
  end

  # A live-VM fork-source backend (mirrors Daytona): snapshot/1 returns a stable
  # id and `fork_source_is_live_vm?/0` is true, so a fork-source parent must be
  # KEPT ALIVE at finalize (not torn down) for its `builds_in` children to fork.
  defmodule LiveForkBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "lf"}}
    @impl true
    def exec(_h, _o), do: {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    @impl true
    def snapshot(_h), do: {:ok, "snap-live-1"}
    @impl true
    def delete_snapshot(_id), do: :ok
    @impl true
    def fork_source_is_live_vm?, do: true
    @impl true
    def teardown(_h) do
      send(:persistent_term.get({__MODULE__, :pid}), :teardown_called)
      :ok
    end
  end

  defp via(job_id), do: {:via, Registry, {Harmont.Engine.SessionRegistry, job_id}}

  defp start(opts) do
    {:ok, pid} = :gen_statem.start_link(via(opts[:job_id]), Session, opts, [])
    pid
  end

  defp barrier(pid) do
    :sys.get_state(pid, 500)
  catch
    :exit, _ -> :stopped
  end

  test "init resumes an :assigned job into :awaiting_agent WITHOUT re-provisioning" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "assigned"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test"
      )

    _ = barrier(pid)
    assert {:awaiting_agent, _} = :sys.get_state(pid)
    # Resumed from DB: no VM was provisioned.
    assert CountingBackend.provisions() == 0

    :gen_statem.stop(pid)
  end

  test "init resumes a :running job into :running WITHOUT re-provisioning" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "running"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test"
      )

    _ = barrier(pid)
    assert {:running, _} = :sys.get_state(pid)
    assert CountingBackend.provisions() == 0

    :gen_statem.stop(pid)
  end

  # NOTE: there is no example test for the :provisioning state_timeout. The
  # backend.provision/1 call runs SYNCHRONOUSLY inside the :internal :provision
  # gen_statem callback, so a blocking provision wedges the callback and the
  # provision_deadline timer can never fire (the process is not back in its event
  # loop). The shared `state_timeout` handler (state in [:provisioning,
  # :awaiting_agent]) is fully exercised via :awaiting_agent below; the
  # :provisioning arm is only reachable if a future backend makes provision async.

  test "awaiting_agent state_timeout drives the job to failed when no agent connects" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    _pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 50,
        infra_retries_left: 0
      )

    # provision ok -> launch_agent -> :awaiting_agent; the agent never connects, so
    # the agent_connect_deadline fires -> sandbox_lost -> :assigned->failed.
    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).error_message == "agent_connect_deadline"
  end

  test "agent_connect_deadline RE-PROVISIONS a fresh VM before failing (infra retry)" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    _pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 50,
        infra_retries_left: 1
      )

    # provision#1 -> :awaiting_agent -> 50ms deadline -> RETRY (teardown +
    # provision#2) -> :awaiting_agent -> 50ms deadline -> retries exhausted ->
    # sandbox_lost -> :failed.
    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).error_message == "agent_connect_deadline"
    # Exactly two provisions: the original plus one infra retry.
    assert CountingBackend.provisions() == 2
  end

  test "launch_agent hands the agent the build's EXTERNAL id, not the internal PK" do
    # AgentSocket.authorize resolves the build by external_build_id; handing the
    # agent the internal primary key 404s every connect (JOB_NOT_FOUND), which
    # the engine only ever observes as agent_connect_deadline.
    :persistent_term.put({CapturingAgentBackend, :pid}, self())
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()
    refute build.external_build_id == build.id

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CapturingAgentBackend,
        api_url: "http://api.test"
      )

    assert_receive {:agent_script, script}, 2_000
    assert script =~ build.external_build_id
    refute script =~ build.id

    :gen_statem.stop(pid)
  end

  test "provision_vm forks the job VM from the parent_snapshot opt" do
    :persistent_term.put({SpecRecordingBackend, :pid}, self())
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    _pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SpecRecordingBackend,
        api_url: "http://api.test",
        parent_snapshot: "snap-parent-123"
      )

    assert_receive {:provision_spec, spec}, 2_000
    assert spec.parent_snapshot == "snap-parent-123"
  end

  test "wall-clock :running timeout broadcasts :cancel and moves to timing_out" do
    build = single_job_build("true")
    job = the_job(build)
    # Resume into :awaiting_agent, then the agent's :started arms the wall-clock
    # with job.timeout_ms (1ms) so it fires immediately.
    job
    |> Job.changeset(%{state: "assigned", timeout_ms: 1})
    |> Repo.update!()

    Phoenix.PubSub.subscribe(Harmont.PubSub, "job_cancel:#{job.id}")

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 60_000
      )

    _ = barrier(pid)
    # agent connects + starts -> :running with a 1ms wall-clock.
    Session.agent_event(job.id, {:started, []})

    # The wall-clock fires: timeout_expired -> :timing_out + a :cancel broadcast.
    assert_receive :cancel, 2_000
    assert :ok == wait_for_state(job.id, "timing_out")
  end

  test "a running job with no agent heartbeat is failed by the liveness watchdog" do
    build = single_job_build("true")
    job = the_job(build)
    # Resume into :awaiting_agent; the agent's :started moves us to :running and
    # arms the heartbeat watchdog (50ms). No heartbeat ever arrives.
    job |> Job.changeset(%{state: "assigned", timeout_ms: 60_000}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 60_000,
        heartbeat_deadline_ms: 50,
        infra_retries_left: 0
      )

    _ = barrier(pid)
    Session.agent_event(job.id, {:started, []})

    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).error_code == "agent_heartbeat_lost"
  end

  test "heartbeat_lost RE-PROVISIONS a fresh VM before failing (infra retry)" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled", timeout_ms: 60_000}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 50,
        heartbeat_deadline_ms: 20,
        infra_retries_left: 1
      )

    _ = barrier(pid)
    # provision#1 -> :awaiting_agent; the agent "starts" -> :running, arming the
    # 20ms liveness watchdog. (`:started` cancels the 50ms agent_connect timer.)
    Session.agent_event(job.id, {:started, []})

    # No heartbeat -> liveness fires -> RETRY (teardown + provision#2) ->
    # :awaiting_agent -> no agent -> agent_connect_deadline -> retries exhausted ->
    # sandbox_lost -> :failed.
    assert :ok == wait_for_state(job.id, "failed")
    # Two provisions prove the liveness watchdog re-provisioned rather than failing
    # the build on the first lost heartbeat.
    assert CountingBackend.provisions() == 2
  end

  test "agent heartbeats reset the liveness watchdog and keep the job running" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "assigned", timeout_ms: 60_000}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test",
        agent_connect_deadline_ms: 60_000,
        heartbeat_deadline_ms: 300
      )

    _ = barrier(pid)
    Session.agent_event(job.id, {:started, []})

    # Beat every 40ms for ~360ms (> the 300ms deadline). The job must NOT be reaped.
    for _ <- 1..9 do
      Session.heartbeat(job.id)
      Process.sleep(40)
    end

    assert Repo.get!(Job, job.id).state == "running"
    :gen_statem.stop(pid)
  end

  test "init resume into :running arms the heartbeat watchdog (regression: was stuck forever)" do
    build = single_job_build("true")
    job = the_job(build)
    # A crash-resumed Session lands directly in :running with no live agent.
    job
    |> Job.changeset(%{state: "running", started_at: DateTime.utc_now(), timeout_ms: 60_000})
    |> Repo.update!()

    _pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test",
        heartbeat_deadline_ms: 50,
        infra_retries_left: 0
      )

    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).error_code == "agent_heartbeat_lost"
  end

  test "cancel before provision short-circuits: no VM is provisioned" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)

    # A cancel landed between SessionSupervisor.start_session and the Session's
    # :provision step: the job is already terminal (scheduled -> canceled). The
    # Session must NOT provision a VM only to tear it back down.
    job |> Job.changeset(%{state: "canceled"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test"
      )

    # The Session finalizes immediately; barrier returns :stopped once it exits.
    _ = barrier(pid)

    refute Process.alive?(pid)
    assert CountingBackend.provisions() == 0
    # State is left terminal — the short-circuit doesn't rewrite it.
    assert Repo.get!(Job, job.id).state == "canceled"
  end

  test "canceling job before provision also short-circuits without provisioning" do
    CountingBackend.start_table()
    build = single_job_build("true")
    job = the_job(build)

    # assigned/running -> canceling is the non-terminal cancel arc; a Session that
    # has not yet provisioned must still skip spinning up a VM.
    job |> Job.changeset(%{state: "canceling"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: CountingBackend,
        api_url: "http://api.test"
      )

    _ = barrier(pid)

    assert CountingBackend.provisions() == 0
  end

  test "cancel on a running session drives the job to canceling then terminal" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "running", started_at: DateTime.utc_now()}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SilentAgentBackend,
        api_url: "http://api.test"
      )

    _ = barrier(pid)
    :ok = Session.cancel(job.id)
    _ = barrier(pid)

    # running + cancel_requested -> :canceling (not terminal yet; awaits agent's
    # terminal report). The job row reflects the canceling state.
    assert :ok == wait_for_state(job.id, "canceling")

    # A subsequent agent terminal report finalizes :canceling -> :canceled.
    Session.agent_event(job.id, {:reported_failed, [exit_code: 1]})
    assert :ok == wait_for_state(job.id, "canceled")
  end

  test "snapshots a passed builds_in-parent and persists snapshot_id, then tears down" do
    :persistent_term.put({SnapshotBackend, :pid}, self())
    {build, base} = builds_in_chain_build()
    base |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: base.id,
        build_id: build.id,
        token: "tok",
        backend: SnapshotBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)
    assert_receive :snapshot_called, 2_000
    assert_receive :teardown_called, 2_000
    base = Repo.get!(Job, base.id)
    assert base.snapshot_id == "snap-fixed-1"
    assert base.state == "passed"
  end

  test "the snapshot is taken BEFORE the job is marked passed (race-closing invariant)" do
    {build, base} = builds_in_chain_build()
    :persistent_term.put({StateProbeSnapshotBackend, :ctx}, {self(), base.id})
    base |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: base.id,
        build_id: build.id,
        token: "tok",
        backend: StateProbeSnapshotBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)
    # The snapshot ran while the job was still "running" — NOT yet "passed", so
    # no observer can ever see `passed` without the snapshot_id already set.
    assert_receive {:snapshot_at_state, "running"}, 2_000

    base = Repo.get!(Job, base.id)
    assert base.state == "passed"
    assert base.snapshot_id == "snap-probe"
  end

  test "a snapshot failure FAILS the job (snapshot_failed) instead of passing without one" do
    {build, base} = builds_in_chain_build()
    base |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: base.id,
        build_id: build.id,
        token: "tok",
        backend: FailingSnapshotBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)
    base = Repo.get!(Job, base.id)
    assert base.state == "failed"
    assert base.error_code == "snapshot_failed"
    assert base.snapshot_id == nil
  end

  test "do_finalize does NOT snapshot a passed job with no builds_in-dependents" do
    :persistent_term.put({SnapshotBackend, :pid}, self())
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: SnapshotBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)
    assert_receive :teardown_called, 2_000
    refute_received :snapshot_called
    assert Repo.get!(Job, job.id).snapshot_id == nil
  end

  test "a fork-source parent is NOT torn down at finalize (live-VM backend keeps it for children)" do
    :persistent_term.put({LiveForkBackend, :pid}, self())
    {build, base} = builds_in_chain_build()
    base |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: base.id,
        build_id: build.id,
        token: "tok",
        backend: LiveForkBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)

    refute_received :teardown_called
    assert Repo.get!(Job, base.id).snapshot_id != nil
  end

  test "a non-parent job IS torn down at finalize on a live-VM backend" do
    :persistent_term.put({LiveForkBackend, :pid}, self())
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    pid =
      start(
        job_id: job.id,
        build_id: build.id,
        token: "tok",
        backend: LiveForkBackend,
        api_url: "http://api.test",
        use_agent: false
      )

    _ = barrier(pid)
    assert_receive :teardown_called, 2_000
  end
end
