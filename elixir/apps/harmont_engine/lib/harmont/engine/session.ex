defmodule Harmont.Engine.Session do
  @moduledoc """
  One job's VM + agent lifecycle, as a `:gen_statem`. Owns ALL live job-state
  transitions (the `Bridge` handles logs + heartbeat only). Registry-unique by
  `job_id` under the `SessionSupervisor` DynamicSupervisor.

  Lifecycle:
    :provisioning  -> backend.provision; on ok, transition :assigned_to_sandbox,
                      then either run_local (Local mode) or launch_agent.
    :awaiting_agent-> (agent mode) wait for the agent's :started, then :running.
    :running       -> agent-driven; wall-clock state_timeout.
    :finalizing    -> teardown VM + Advance.after_job; stop.

  `restart: :temporary`: on crash the work is recovered by a re-run `CI.JobRunner`
  or `CI.ReconcileJob`, NOT by the supervisor. `init/1` resumes from the current
  `job.state` so a re-start of an already-assigned/running job does not provision
  a SECOND VM.
  """
  @behaviour :gen_statem
  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  import Ecto.Query
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{Advance, Bootstrap, CI, Transition, VmSpec}
  alias Harmont.Engine.Fsm.JobState
  alias Harmont.Sandboxes
  alias HarmontVm.Backend, as: VmBackend

  # --- public API -----------------------------------------------------------

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:job_id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts), do: :gen_statem.start_link(via(opts[:job_id]), __MODULE__, opts, [])

  defp via(job_id), do: {:via, Registry, {Harmont.Engine.SessionRegistry, job_id}}

  @doc "AgentSocket forwards an agent state transition (+ extra, e.g. exit_code) here."
  def agent_event(job_id, event), do: cast_if_alive(job_id, {:agent, event})

  @doc "Request cancellation of a live job's Session."
  def cancel(job_id), do: cast_if_alive(job_id, :cancel)

  @doc """
  Agent proof-of-life. Re-arms the Session's `:running` liveness watchdog so a
  job whose agent is still beating is never reaped as lost. No-op if the Session
  is not alive (cast_if_alive).
  """
  def heartbeat(job_id), do: cast_if_alive(job_id, :heartbeat)

  # cast to a dead :via raises; look the pid up and no-op if it's gone.
  defp cast_if_alive(job_id, msg) do
    case Registry.lookup(Harmont.Engine.SessionRegistry, job_id) do
      [{pid, _}] -> :gen_statem.cast(pid, msg)
      [] -> :ok
    end

    :ok
  end

  # --- gen_statem callbacks --------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  # Default state deadlines (ms). Overridable via opts (:provision_deadline_ms /
  # :agent_connect_deadline_ms) so tests can drive the timeout arcs with tiny
  # values without sleeping for the production limits.
  @provision_deadline_ms 120_000
  @agent_connect_deadline_ms 90_000
  # Max gap between agent heartbeats while :running before we declare the agent
  # dead and drive the job terminal. The agent beats every 5s (HARMONT_AGENT_
  # HEARTBEAT_SEC), so 30s == 6 missed beats. Overridable via opts for tests.
  @heartbeat_deadline_ms 30_000

  # How many times a Session re-provisions a fresh VM on an INFRA deadline (agent
  # never connected, or agent heartbeat lost while :running) before driving the
  # job terminal. Bounds the retry so a persistently-flaky VM can't loop forever.
  # Overridable per-Session via the `:infra_retries_left` opt (tests). `init/1`
  # reads `config :harmont_engine, :infra_retries` if it is ever set, otherwise
  # this attribute — there is no env-var knob today, so prod uses this default.
  @infra_retries 2

  @impl true
  def init(opts) do
    data =
      Map.merge(
        %{
          handle: nil,
          backend: VmBackend.impl(),
          token: nil,
          provision_deadline_ms: @provision_deadline_ms,
          agent_connect_deadline_ms: @agent_connect_deadline_ms,
          heartbeat_deadline_ms: @heartbeat_deadline_ms,
          infra_retries_left: Application.get_env(:harmont_engine, :infra_retries, @infra_retries)
        },
        Map.new(opts)
      )

    job = Harmont.Repo.get!(Job, data.job_id)

    # Attach the OTel context propagated from CI.JobRunner.perform (the Oban worker
    # span set by OpentelemetryOban) so this gen_statem process inherits the trace.
    # Defensive: if no ctx was passed (e.g. a direct test start), use a fresh context.
    otel_ctx = data[:otel_ctx] || OpenTelemetry.Ctx.get_current()
    _token = OpenTelemetry.Ctx.attach(otel_ctx)

    # Start a long-lived "job.run" span that will be ended in do_finalize/1.
    # gen_statem cannot hold a with_span open across callbacks, so we use
    # start_span + set_current_span to keep it alive across state transitions.
    # OTel is a no-op when the SDK is not running (e.g. test env) — this is safe.
    # Build identity on the span so a wedged/slow build is filterable by id (the
    # 2026-06-10 investigation could not tie job.run spans to a build number).
    build = Harmont.Repo.get!(Build, job.build_id)
    # Tenant identity (org + pipeline) so a wedged/slow build is sliceable by
    # tenant. `pipeline_id` is nullable (executor-only builds), so drop nil keys
    # rather than emit literal-nil attributes.
    tenant = CI.tenant_for_build(job.build_id)

    span =
      Tracer.start_span("job.run", %{
        attributes:
          %{
            "job.id" => data.job_id,
            "build.id" => job.build_id,
            "build.external_id" => build.external_build_id,
            "job.step_key" => job.step_key,
            "vm.backend" => inspect(data.backend),
            "harmont.org.id" => tenant.org_id,
            "harmont.pipeline.id" => tenant.pipeline_id
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
      })

    _ = Tracer.set_current_span(span)
    data = Map.put(data, :otel_span, span)

    # Resume from the DB state so a temporary restart doesn't re-provision.
    case JobState.cast(job.state) do
      {:ok, :assigned} -> {:ok, :awaiting_agent, data}
      {:ok, :running} -> {:ok, :running, data}
      _ -> {:ok, :provisioning, data, [{:next_event, :internal, :provision}]}
    end
  end

  # --- state_enter timeouts (catch-all MUST stay LAST among :enter clauses) --

  @impl true
  def handle_event(:enter, _old, :provisioning, data),
    do:
      {:keep_state_and_data, [{:state_timeout, data.provision_deadline_ms, :provision_deadline}]}

  def handle_event(:enter, _old, :awaiting_agent, data),
    do:
      {:keep_state_and_data,
       [{:state_timeout, data.agent_connect_deadline_ms, :agent_connect_deadline}]}

  # Entering :running (via :started OR a crash-resume in init/1) arms the
  # heartbeat watchdog. This is the single guarantee that a dead agent always
  # drives the job terminal — it covers both the resume-into-:running gap and the
  # post-wall-clock idle (the gen_statem stays :running there with no other timer).
  def handle_event(:enter, _old, :running, data),
    do: {:keep_state_and_data, [liveness_timeout(data)]}

  def handle_event(:enter, _old, _state, _data), do: :keep_state_and_data

  # --- provisioning ----------------------------------------------------------

  def handle_event(:internal, :provision, :provisioning, data) do
    job = Harmont.Repo.get!(Job, data.job_id)

    # Re-read the (possibly just-canceled) job state BEFORE spending a VM. A cancel
    # that lands between SessionSupervisor.start_session and this provision flips
    # the job to :canceled (scheduled -> canceled) or signals us; provisioning it
    # only to tear it back down is wasted work + orphaned-VM latency. Short-circuit
    # to finalizing if the job is already terminal/canceling — this is what the
    # moduledoc means by "later Sessions see the terminal/canceling state and do
    # not re-run."
    if terminal_or_canceling?(job.state) do
      {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]}
    else
      provision_vm(job, data)
    end
  end

  # Agent never connected within the budget. The VM came up but the agent never
  # reached the engine — almost always a transient Daytona/boot fault, not a job
  # failure. Re-provision a fresh VM (bounded) before giving up. The span event
  # name is preserved (`session.agent_connect_deadline`) for existing telemetry.
  def handle_event(:state_timeout, :agent_connect_deadline, :awaiting_agent, data) do
    Tracer.add_event("session.agent_connect_deadline", %{
      "session.deadline_ms" => data.agent_connect_deadline_ms,
      "session.state" => "awaiting_agent"
    })

    reprovision_or_lose(data, "agent_connect_deadline", error_message: "agent_connect_deadline")
  end

  # Provision itself never returned. `backend.provision/1` runs SYNCHRONOUSLY in
  # the :internal :provision callback, so this only fires if a future async
  # backend leaves provisioning wedged. Do NOT retry — a second provision could
  # race the first still-in-flight one; surface it instead.
  def handle_event(:state_timeout, :provision_deadline, :provisioning, data) do
    Tracer.add_event("session.provision_deadline", %{
      "session.deadline_ms" => data.provision_deadline_ms,
      "session.state" => "provisioning"
    })

    _ = Transition.apply(data.job_id, :sandbox_lost, error_message: "provision_deadline")
    {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]}
  end

  # --- awaiting_agent / running: agent-driven --------------------------------

  def handle_event(:cast, {:agent, {:assigned_to_sandbox, _extra}}, :awaiting_agent, data) do
    _ = Transition.apply(data.job_id, :assigned_to_sandbox)
    {:keep_state, data}
  end

  def handle_event(:cast, {:agent, {:started, _extra}}, state, data)
      when state in [:awaiting_agent, :provisioning] do
    _ = Transition.apply(data.job_id, :started)
    job = Harmont.Repo.get!(Job, data.job_id)
    {:next_state, :running, data, [{:state_timeout, job.timeout_ms || 3_600_000, :wall_clock}]}
  end

  def handle_event(:state_timeout, :wall_clock, :running, data) do
    _ = Transition.apply(data.job_id, :timeout_expired)
    # Signal a wedged agent to stop; AgentSocket.handle_info(:cancel) pushes CancelMsg.
    :ok = Phoenix.PubSub.broadcast(Harmont.PubSub, "job_cancel:#{data.job_id}", :cancel)
    # The agent will report a terminal state; the ReconcileJob backstop finalizes
    # if it never does.
    {:keep_state, data}
  end

  # Each heartbeat (routed from AgentSocket) resets the liveness watchdog. We stay
  # in :running, so re-arming the generic timer here is the reset.
  def handle_event(:cast, :heartbeat, :running, data),
    do: {:keep_state_and_data, [liveness_timeout(data)]}

  # No heartbeat within the deadline: the agent/VM is gone. The FSM stays in
  # :running after the wall-clock fires (only the job ROW moves to timing_out),
  # so this watchdog is still armed there — sandbox_lost is a legal job-row arc
  # from running/timing_out/canceling, rescuing a job whose wall-clock already
  # fired and left it idle.
  def handle_event({:timeout, :liveness}, :expired, :running, data) do
    Tracer.add_event("session.heartbeat_lost", %{
      "deadline_ms" => data.heartbeat_deadline_ms
    })

    reprovision_or_lose(data, "heartbeat_lost",
      error_code: "agent_heartbeat_lost",
      error_message: "no agent heartbeat within #{data.heartbeat_deadline_ms}ms"
    )
  end

  def handle_event(:cast, {:agent, {:reported_passed, extra}}, _state, data) do
    _ = apply_passed(Harmont.Repo.get!(Job, data.job_id), data, extra)
    maybe_finalize(data)
  end

  def handle_event(:cast, {:agent, {ev, extra}}, _state, data)
      when ev in [:reported_failed, :sandbox_lost, :timeout_expired] do
    _ = Transition.apply(data.job_id, ev, extra)
    maybe_finalize(data)
  end

  def handle_event(:cast, :cancel, _state, data) do
    _ = Transition.apply(data.job_id, :cancel_requested)
    maybe_finalize(data)
  end

  # --- finalizing ------------------------------------------------------------

  def handle_event(:internal, :finalize, :finalizing, data), do: do_finalize(data)

  # DROP all other illegal arcs for free.
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # --- provisioning helpers --------------------------------------------------

  # Record which VM ran this job, captured at provision time, so the usage
  # breakdown can trace a charge back to the exact sandbox. Best-effort and
  # backend-optional: backends without handle_id/1 (e.g. test mocks) skip it.
  defp persist_vm_handle(job_id, backend, handle) do
    if function_exported?(backend, :handle_id, 1) do
      Harmont.Repo.update_all(
        from(j in Job, where: j.id == ^job_id),
        set: [vm_handle: backend.handle_id(handle)]
      )
    end
  end

  # Record a freshly-provisioned sandbox in the registry, keyed by the backend's
  # stable handle id. Gated on handle_id/1 (test/Local backends without it skip
  # recording, exactly like persist_vm_handle/3). Best-effort: a registry write
  # must never fail a job — the reaper reconciles anything we miss.
  @doc false
  def record_sandbox(job, data, handle) do
    if function_exported?(data.backend, :handle_id, 1) do
      _ =
        Sandboxes.record(%{
          provider: HarmontVm.Backend.provider(),
          external_id: data.backend.handle_id(handle),
          kind: "job",
          job_id: job.id,
          build_id: job.build_id
        })
    end

    :ok
  end

  # Job finalised and its VM is being released: flip the registry row. A
  # kept-alive fork parent (live-VM backend whose VM at least one `builds_in`
  # child forks) stays `active` and is relabelled `fork_parent` — the
  # build-terminal reap deletes the fork tree later. Otherwise mark it `deleted`.
  # Public for tests; gated on handle_id/1 like record_sandbox/3.
  @doc false
  def release_sandbox(job, data, handle) do
    if function_exported?(data.backend, :handle_id, 1) do
      external_id = data.backend.handle_id(handle)

      if fork_parent_in_registry?(job, data) do
        Sandboxes.mark_fork_parent(HarmontVm.Backend.provider(), external_id)
      else
        Sandboxes.mark_deleted(HarmontVm.Backend.provider(), external_id)
      end
    end

    :ok
  end

  # Registry-side fork-parent predicate: the backend keeps fork sources as live
  # VMs AND at least one sibling `builds_in` this job. This mirrors do_finalize's
  # keep-alive decision (in the real flow a kept-alive parent has both a snapshot
  # and builds_in dependents), but is keyed on the durable DAG shape rather than
  # the just-written snapshot_id so it holds independent of write ordering.
  defp fork_parent_in_registry?(%Job{} = job, data) do
    b = data.backend

    function_exported?(b, :fork_source_is_live_vm?, 0) and b.fork_source_is_live_vm?() and
      has_builds_in_dependents?(job)
  end

  # A generic (named) gen_statem timeout, independent of the :state_timeout used
  # for provision/agent-connect/wall-clock. Re-emitting it replaces the prior
  # timer (the reset). It is NOT auto-cancelled on a state change, so the
  # catch-all handle_event drops any late :liveness event fired outside :running.
  defp liveness_timeout(data),
    do: {{:timeout, :liveness}, data.heartbeat_deadline_ms, :expired}

  defp terminal_or_canceling?(state) do
    case JobState.cast(state) do
      {:ok, s} -> JobState.terminal?(s) or s in [:canceling, :timing_out]
      # Unknown state on a rolling deploy: don't provision speculatively.
      :error -> false
    end
  end

  # Bounded infra-retry. An agent that never connected, or that stopped
  # heartbeating while :running, means the VM/agent is gone — not that the job's
  # command failed. Tear the dead VM down and re-enter :provisioning for a fresh
  # one (Daytona issues a unique sandbox NAME per create, so the corpse can't
  # 409-collide), up to `infra_retries_left` times. Only when the budget is spent
  # do we drive the job terminal with `lost_opts`. The job row stays
  # :assigned/:running across the retry; the re-run agent's duplicate
  # :assigned_to_sandbox/:started transitions are illegal-from-that-state and so
  # are dropped by the FSM's fire-forward design.
  defp reprovision_or_lose(data, reason, lost_opts) do
    if data.infra_retries_left > 0 do
      Tracer.add_event("session.infra_retry", %{
        "session.infra_retry.reason" => reason,
        "session.infra_retries_left" => data.infra_retries_left
      })

      data =
        data
        |> teardown_for_retry()
        |> Map.update!(:infra_retries_left, &(&1 - 1))

      {:next_state, :provisioning, data, [{:next_event, :internal, :provision}]}
    else
      _ = Transition.apply(data.job_id, :sandbox_lost, lost_opts)
      {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]}
    end
  end

  # Release the dead VM before a retry re-provisions. Best-effort, mirroring
  # terminate/1: tear down + mark the registry row deleted so the corpse doesn't
  # leak provider quota. A VM we're abandoning mid-retry is never a fork source to
  # keep alive, so this is always a full teardown.
  defp teardown_for_retry(%{handle: nil} = data), do: data

  defp teardown_for_retry(data) do
    _ = data.backend.teardown(data.handle)

    if function_exported?(data.backend, :handle_id, 1) do
      Sandboxes.mark_deleted(HarmontVm.Backend.provider(), data.backend.handle_id(data.handle))
    end

    %{data | handle: nil}
  end

  defp provision_vm(job, data) do
    spec =
      Map.merge(VmSpec.resources(), %{
        name: job.id,
        base_snapshot: data[:base_snapshot],
        # `builds_in` lineage: fork this job's VM from the parent step's post-run
        # disk snapshot so installed toolchains/state carry forward. nil for root
        # steps (provision then falls back to base_snapshot, then the blueprint).
        parent_snapshot: data[:parent_snapshot]
      })

    # Move scheduled -> assigned BEFORE provisioning, so a provision FAILURE can
    # legally transition assigned -> sandbox_lost -> failed. (scheduled -> sandbox_lost
    # is not a legal arc; transitioning after provision left a failed job stuck in
    # :scheduled forever — the build would hang.) The agent's later
    # JOB_ASSIGNED_TO_SANDBOX then becomes a harmless no-op on :assigned.
    _ = Transition.apply(job.id, :assigned_to_sandbox)

    case data.backend.provision(spec) do
      {:ok, handle} ->
        d = %{data | handle: handle}
        _ = persist_vm_handle(job.id, data.backend, handle)
        _ = record_sandbox(job, data, handle)
        if data[:use_agent] == false, do: run_local(job, d), else: launch_agent(job, d)

      {:error, reason} ->
        _ =
          Transition.apply(job.id, :sandbox_lost,
            error_code: "provision_failed",
            error_message: inspect(reason)
          )

        {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]}
    end
  end

  # --- agent mode: launch the agent, wait for it to drive transitions --------

  defp launch_agent(job, data) do
    # The agent authenticates its WebSocket by announcing the build's PUBLIC
    # identifier: `AgentSocket.authorize` resolves the build via
    # `external_build_id` (and the in-VM source endpoint is keyed by it too).
    # `data.build_id` is the internal primary key, so translate here — handing
    # the agent the PK makes every connect 404 with JOB_NOT_FOUND, which the
    # engine only ever observes as the 90s `agent_connect_deadline`.
    external_build_id = Harmont.Repo.get!(Build, job.build_id).external_build_id

    script =
      Bootstrap.render_agent(%{
        build_id: external_build_id,
        job_id: job.id,
        api_url: data.api_url,
        token: data.token
      })

    {:ok, _task} =
      Task.start(fn ->
        data.backend.exec(data.handle, %{
          command: script,
          hard_cap_ms: (job.timeout_ms || 3_600_000) + 60_000
        })
      end)

    {:next_state, :awaiting_agent, data}
  end

  # --- local mode: provision then run the command synchronously --------------

  defp run_local(job, data) do
    _ = Transition.apply(job.id, :started)

    res =
      data.backend.exec(data.handle, %{
        command: job.command,
        hard_cap_ms: job.timeout_ms || 3_600_000
      })

    _ =
      case res do
        {:ok, %{exit_code: 0}} -> apply_passed(job, data, exit_code: 0)
        {:ok, %{exit_code: c}} -> Transition.apply(job.id, :reported_failed, exit_code: c)
        {:error, :timed_out} -> Transition.apply(job.id, :timeout_expired)
        {:error, e} -> Transition.apply(job.id, :sandbox_lost, error_message: inspect(e))
      end

    {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]}
  end

  defp maybe_finalize(data) do
    job = Harmont.Repo.get!(Job, data.job_id)

    if JobState.terminal?(JobState.cast!(job.state)),
      do: {:next_state, :finalizing, data, [{:next_event, :internal, :finalize}]},
      else: {:keep_state, data}
  end

  @doc false
  # Pure: the attribute map recorded on the job.run span at finalize. Public only
  # so it can be unit-tested without an OTel exporter (see telemetry_test.exs).
  # nil error fields (a passed job) are dropped so the span carries the KEY only
  # when there's a real value — filterable by absence in Honeycomb, not a literal nil.
  def span_finish_attrs(%Job{} = job) do
    %{
      "job.final_state" => job.state,
      "job.error_code" => job.error_code,
      "job.error_message" => job.error_message
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp do_finalize(data) do
    job = Harmont.Repo.get!(Job, data.job_id)

    # A live-VM fork source (Daytona) must outlive its `builds_in` children so
    # they can fork it; the build-terminal reap deletes the fork tree. Runloop's
    # snapshots are independent disk artifacts, so it always tears down here.
    # Always drop the handle once finalize has dealt with it — whether we kept the
    # VM alive as a fork source or tore it down here. terminate/1 (which runs on
    # the subsequent {:stop, :normal}) then sees no handle and is a pure crash-path
    # backstop, so the clean path makes exactly ONE teardown + registry write
    # rather than two.
    data =
      if keep_alive_as_fork_source?(job, data) do
        if data.handle, do: release_sandbox(job, data, data.handle)
        %{data | handle: nil}
      else
        if data.handle do
          data.backend.teardown(data.handle)
          release_sandbox(job, data, data.handle)
        end

        %{data | handle: nil}
      end

    # Record the final job state + error detail on the span before ending it.
    Tracer.set_attributes(span_finish_attrs(job))

    # End the long-lived span started in init/1. Restore context so it is current,
    # then call end_span/0 which also clears it. No-op if OTel SDK is not running.
    span = data[:otel_span]

    _ =
      if span do
        _ = Tracer.set_current_span(span)
        Tracer.end_span()
      end

    # prompt DAG advance; CI.JobRunner / CI.ReconcileJob are the durable backstops.
    Advance.after_job(data.job_id, data[:token])
    {:stop, :normal, data}
  end

  # A job whose `snapshot_id` is set became a fork source: on a live-VM backend
  # (Daytona) that id IS the live parent sandbox, which its `builds_in` children
  # fork from, so it must NOT be torn down here — the build-terminal reap deletes
  # the fork tree. Runloop has no `fork_source_is_live_vm?/0`, so this is false
  # and its behaviour is unchanged.
  defp keep_alive_as_fork_source?(%Job{snapshot_id: sid}, data) when is_binary(sid) do
    b = data.backend
    function_exported?(b, :fork_source_is_live_vm?, 0) and b.fork_source_is_live_vm?()
  end

  defp keep_alive_as_fork_source?(_job, _data), do: false

  # Apply the terminal `:reported_passed` transition for a job that just passed.
  #
  # For a job that some sibling `builds_in`, the VM disk is snapshotted HERE —
  # BEFORE the `passed` state is written — and `snapshot_id` is persisted in the
  # SAME `Transition.apply` write. This is the race-closing invariant: the
  # instant any observer (a sibling's `Advance`, the reconcile backstop, the
  # child's own provision) can see this job as `passed`, its `snapshot_id` is
  # already durable. Writing `passed` first (the old `do_finalize` order) let a
  # child provision in the gap and fork from the blueprint with no toolchain.
  #
  # If the snapshot itself FAILS, the job is FAILED (`snapshot_failed`) rather
  # than passed-without-a-snapshot: a `builds_in` child must never silently boot
  # the blueprint and run without its parent's toolchain.
  defp apply_passed(%Job{} = job, data, extra) do
    if snapshot_parent?(job, data) do
      case data.backend.snapshot(data.handle) do
        {:ok, snapshot_id} ->
          Transition.apply(
            job.id,
            :reported_passed,
            Keyword.put(extra, :snapshot_id, snapshot_id)
          )

        {:error, reason} ->
          Transition.apply(job.id, :reported_failed,
            error_code: "snapshot_failed",
            error_message: "VM snapshot failed: #{inspect(reason)}"
          )
      end
    else
      Transition.apply(job.id, :reported_passed, extra)
    end
  end

  # A job is a snapshot parent when we hold a live handle whose backend can
  # snapshot AND at least one sibling job `builds_in` it. (Leaves and the
  # Local/dev backend take no snapshot.)
  defp snapshot_parent?(%Job{} = job, data) do
    data.handle != nil and
      function_exported?(data.backend, :snapshot, 1) and
      has_builds_in_dependents?(job)
  end

  defp has_builds_in_dependents?(%Job{build_id: build_id, step_key: step_key}) do
    Harmont.Repo.exists?(
      from(j in Job, where: j.build_id == ^build_id and j.builds_in == ^step_key)
    )
  end

  @impl true
  def terminate(_reason, _state, data) do
    if data[:handle] do
      data.backend.teardown(data.handle)

      if function_exported?(data.backend, :handle_id, 1) do
        Sandboxes.mark_deleted(HarmontVm.Backend.provider(), data.backend.handle_id(data.handle))
      end
    end

    :ok
  end
end
