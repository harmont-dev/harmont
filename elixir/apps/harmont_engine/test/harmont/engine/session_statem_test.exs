defmodule Harmont.Engine.SessionStatemTest do
  @moduledoc """
  Model-based property test of the `Session` gen_statem lifecycle (Phase 2.2).

  We start a real `Session` over a deterministic in-process `CountingBackend`
  (a `VmBackend` stub that counts provision/exec/teardown calls and never does
  any I/O), then drive a random sequence of the agent events + cancel the
  Session accepts. The model tracks the legal lifecycle; the invariants checked
  are:

    * No event sequence ever crashes the Session process — illegal arcs are
      dropped by the engine (`JobState.transition/2` returns `:error`, the
      catch-all `handle_event` clause keeps the state).
    * Provision is called AT MOST ONCE (a resume-from-DB or a redundant event
      must never spin up a second VM).
    * Teardown is eventually called exactly when the Session finalizes, and the
      job row ends in a terminal state once the Session has stopped.

  ## Sandbox ownership

  `Harmont.DataCase` checks out a SHARED-mode connection owned by the
  test process. The `Session` is a separate gen_statem process, but shared mode
  lets it use the same sandboxed connection, so all of its DB work is rolled
  back with the test. We run each generated command synchronously and use
  `:sys.get_state/1` (or process-liveness checks) as a barrier so the
  asynchronous casts have been processed before a post-condition reads state.
  """
  use Harmont.DataCase, async: false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  alias Harmont.Builds.Job
  alias Harmont.Engine.{MaterializeFixture, Session}
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  # --- counting VM backend (pure, in-process, deterministic) ----------------

  defmodule CountingBackend do
    @moduledoc false
    @behaviour HarmontVm.Backend

    # Counters live in the process dictionary of a named Agent so the Session
    # process (a different pid) shares them with the test process. Deterministic:
    # no sleeps, no real I/O.
    def start_counters do
      _ = :ets.new(:session_statem_counters, [:public, :named_table, :set])
      :ets.insert(:session_statem_counters, {:provision, 0})
      :ets.insert(:session_statem_counters, {:exec, 0})
      :ets.insert(:session_statem_counters, {:teardown, 0})
      :ok
    end

    def reset_counters do
      if :ets.whereis(:session_statem_counters) != :undefined do
        :ets.delete(:session_statem_counters)
      end

      start_counters()
    end

    def count(key), do: :ets.lookup_element(:session_statem_counters, key, 2)

    defp bump(key), do: :ets.update_counter(:session_statem_counters, key, 1)

    @impl true
    def provision(_spec) do
      _ = bump(:provision)
      {:ok, %{vm: "counting-vm"}}
    end

    @impl true
    def exec(_handle, _opts) do
      _ = bump(:exec)
      # Agent-mode launch: the Session ignores this result (the agent drives
      # transitions via casts). Return a benign success.
      {:ok, %{exit_code: 0, stdout: "", stderr: ""}}
    end

    @impl true
    def teardown(_handle) do
      _ = bump(:teardown)
      :ok
    end
  end

  # --- the property ---------------------------------------------------------

  property "no agent-event sequence crashes the Session; the job reaches terminal",
           [:verbose, numtests: 100] do
    forall cmds <- commands(__MODULE__) do
      CountingBackend.reset_counters()

      {history, state, result} = run_commands(__MODULE__, cmds)

      # Drain any session we left alive, then assert the global invariants that
      # only hold once the lifecycle has fully settled.
      final_ok = drain_and_check(state)

      (result == :ok and final_ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result, pretty: true)}
        provision=#{CountingBackend.count(:provision)} \
        teardown=#{CountingBackend.count(:teardown)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # After the command sequence, the Session may still be alive mid-flight or
  # already stopped. Invariants:
  #   * provision was called at most once,
  #   * if the Session has stopped, teardown ran and the job row is terminal.
  defp drain_and_check(%{job_id: nil}), do: CountingBackend.count(:provision) <= 1

  defp drain_and_check(%{job_id: job_id, pid: pid}) do
    provisions_ok = CountingBackend.count(:provision) <= 1

    settled? = wait_until_settled(pid)

    job = Repo.get!(Job, job_id)

    if settled? do
      # Session stopped: teardown must have run and the job must be terminal.
      provisions_ok and CountingBackend.count(:teardown) >= 1 and terminal?(job.state)
    else
      # Session still alive (legitimately mid-flight): just the provision bound.
      provisions_ok
    end
  end

  # Block briefly for the Session to either reach a settled (stopped) state or
  # confirm it is still alive mid-flight. Deterministic-ish: bounded retries.
  defp wait_until_settled(pid) do
    Enum.reduce_while(1..50, false, fn _, _ -> settled_step(pid) end)
  end

  defp settled_step(pid) do
    # Flush its mailbox so any in-flight cast is processed, then re-check
    # liveness. A stopped Session means the lifecycle has settled.
    _ = if Process.alive?(pid), do: safe_sys_state(pid)
    if Process.alive?(pid), do: {:cont, false}, else: {:halt, true}
  end

  defp safe_sys_state(pid) do
    :sys.get_state(pid, 100)
  catch
    :exit, _ -> :gone
  end

  @terminal ~w(passed failed skipped canceled timed_out)
  defp terminal?(s), do: s in @terminal

  # --- model ----------------------------------------------------------------
  # state:
  #   %{
  #     job_id: binary | nil,  # nil before start_session
  #     pid:    pid | nil,
  #     phase:  :scheduled | :awaiting | :running | :terminal  # coarse model
  #   }

  def initial_state, do: %{job_id: nil, pid: nil, phase: :pre}

  def command_gen(%{job_id: nil}), do: {:start_session, []}

  def command_gen(%{job_id: job_id}) do
    frequency([
      {6,
       {:agent_event,
        [
          job_id,
          oneof([
            :assigned_to_sandbox,
            :started,
            :reported_passed,
            :reported_failed,
            :sandbox_lost,
            :timeout_expired
          ])
        ]}},
      {1, {:cancel, [job_id]}}
    ])
  end

  # --- commands -------------------------------------------------------------

  defcommand :start_session do
    def impl, do: do_start_session()

    def pre(%{job_id: nil}, _), do: true
    def pre(_, _), do: false

    def next(state, _args, {job_id, pid}),
      do: %{state | job_id: job_id, pid: pid, phase: :scheduled}

    def post(_state, _args, {_job_id, pid}), do: is_pid(pid) and Process.alive?(pid)
  end

  defcommand :agent_event do
    def impl(job_id, ev), do: do_agent_event(job_id, ev)

    def pre(%{job_id: nil}, _), do: false
    def pre(_, _), do: true

    # The engine drops illegal arcs; the model only needs to know the lifecycle
    # is progressing-or-stable, so it stays coarse here.
    def next(state, _args, _res), do: state

    # Per-event invariants: the Session never crashes (a genuine crash would
    # abnormally exit and, via the start_link below, take down this test process
    # — so reaching the post-condition at all already proves no crash); and
    # provision stays bounded; and if the Session has stopped, it did so cleanly
    # with the job in a terminal state.
    def post(state, [_job_id, _ev], _res), do: event_post(state)
  end

  defcommand :cancel do
    def impl(job_id), do: do_cancel(job_id)

    def pre(%{job_id: nil}, _), do: false
    def pre(_, _), do: true

    def next(state, _args, _res), do: state

    def post(state, [_job_id], _res), do: event_post(state)
  end

  defp event_post(%{pid: pid, job_id: job_id}) do
    provisions_ok = CountingBackend.count(:provision) <= 1

    if Process.alive?(pid) do
      provisions_ok
    else
      # The Session stopped: teardown must have run and the job must be
      # terminal (a clean finalize, not a crash).
      provisions_ok and CountingBackend.count(:teardown) >= 1 and
        terminal?(Repo.get!(Job, job_id).state)
    end
  end

  # --- impls ----------------------------------------------------------------

  defp do_start_session do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [%CommandStep{key: "only", cmd: "true"}]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    job = Repo.one!(from(j in Job, where: j.build_id == ^build.id))
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    # Agent mode (use_agent not false) so provision happens then the Session
    # awaits the agent events we will inject.
    opts = [
      job_id: job.id,
      build_id: build.id,
      token: "tok",
      backend: CountingBackend,
      api_url: "http://api.test"
    ]

    # Trap exits so an ABNORMAL Session crash arrives as an {:EXIT, _, reason}
    # message instead of killing the PropEr command runner — the post-condition
    # then observes the dead pid + non-terminal job and fails loudly with a
    # shrunk counterexample (rather than the whole property aborting).
    _ = Process.flag(:trap_exit, true)

    {:ok, pid} = :gen_statem.start_link(via(job.id), Session, opts, [])

    # Allow the synchronous init/internal-provision to run so provision is
    # counted before any event is injected.
    _ = barrier(pid)

    {job.id, pid}
  end

  defp do_agent_event(job_id, ev) do
    :ok = Session.agent_event(job_id, {ev, agent_extra(ev)})
    # Barrier: flush the cast through the gen_statem before the post-condition.
    _ = barrier(lookup(job_id))
    :ok
  end

  defp do_cancel(job_id) do
    :ok = Session.cancel(job_id)
    _ = barrier(lookup(job_id))
    :ok
  end

  # extras the real engine threads for terminal events (mirrors AgentSocket).
  defp agent_extra(:reported_passed), do: [exit_code: 0]
  defp agent_extra(:reported_failed), do: [exit_code: 1]
  defp agent_extra(:sandbox_lost), do: [error_message: "lost"]
  defp agent_extra(_), do: []

  # --- helpers --------------------------------------------------------------

  defp via(job_id), do: {:via, Registry, {Harmont.Engine.SessionRegistry, job_id}}

  defp lookup(job_id) do
    case Registry.lookup(Harmont.Engine.SessionRegistry, job_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Synchronous barrier: if the process is alive, :sys.get_state flushes its
  # mailbox (processing prior casts). If it has stopped (finalized), that's a
  # clean exit, not a crash — catch it and continue.
  defp barrier(nil), do: :ok

  defp barrier(pid) do
    :sys.get_state(pid, 200)
  catch
    :exit, _ -> :stopped
  end
end
