defmodule Harmont.Engine.CI do
  @moduledoc """
  Oban-driven DAG orchestration. `start_build/2` enqueues runners for a freshly
  materialized build's root jobs; `enqueue_runner/2` enqueues a single runner.
  The raw runner token is threaded through the Oban job args so each `Session`
  can launch its agent (and so `CI.ReconcileJob` can re-target a build's runners).

  `CI.JobRunner` and `CI.ReconcileJob` live in this file as one logical unit.
  """
  import Ecto.Query
  alias Harmont.Builds.{Build, Job, JobDep}
  alias Harmont.Engine.Transition

  @doc "Build the (unsaved) Oban changeset for a job's runner, threading the token."
  def runner_changeset(%Job{} = job, token) do
    # credo:disable-for-next-line Credo.Check.Design.AliasUsage
    Harmont.Engine.CI.JobRunner.new(args(job, token), meta: meta(job))
  end

  defp args(%Job{} = job, token) do
    %{"job_id" => job.id, "build_id" => job.build_id, "token" => token}
  end

  # `meta` carries the owning org, the job_id, and the build_id. None live in
  # `args`, which Task 8 encrypts (whole-args, fresh IV per insert) so args can no
  # longer be matched by `unique:` OR queried by SQL (the ciphertext lives under
  # `args->'data'`). The runners therefore key uniqueness off `meta.job_id` (see
  # the `unique:` opts on JobRunner/ReconcileJob); `meta.build_id` lets
  # `Cancel.request/1` find a build's runners by `meta->>'build_id'`; org_id stays
  # available as a future Oban `partition:` key. `meta` is never encrypted by Pro.
  #
  # A per-org partition is intentionally NOT applied to the `:ci` queue:
  #   * Oban partitions the global limit XOR the rate limit, not both, and `:ci`'s
  #     rate limit is the global Freestyle cap (Task 2) we must not partition away.
  #   * Per-org concurrency is ineffective here anyway: `CI.JobRunner` fire-and-
  #     returns (the `Session` provisions the VM after `process` exits, in ~ms),
  #     so a per-org concurrency limit would almost never bind.
  @doc false
  # Public so `ReconcileSupport.enqueue/2` can put the same meta in its job
  # without a compile-time dependency on the worker module.
  def meta(%Job{} = job),
    do: %{org_id: org_id_for_build(job.build_id), job_id: job.id, build_id: job.build_id}

  # Cheapest correct resolution: a single SELECT joining the build to its pipeline.
  # `pipeline_id` is nullable (executor-only builds have no pipeline) so this can
  # legitimately return nil; GitHub/UI/API builds always carry one.
  @spec org_id_for_build(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  defp org_id_for_build(build_id) do
    Harmont.Repo.one(
      from(b in Build,
        join: p in assoc(b, :pipeline),
        where: b.id == ^build_id,
        select: p.organization_id
      )
    )
  end

  @doc """
  Resolve a build's tenant identity (org + pipeline) for telemetry.

  `left_join` (not `join`) because `pipeline_id` is nullable — executor-only
  builds have no pipeline, so both keys are legitimately `nil` there; GitHub/UI/
  API builds always carry one. Public so `Session.init/1` can stamp the long-lived
  `job.run` span with `harmont.org.id`/`harmont.pipeline.id` without a second query
  helper. One extra `SELECT` per session start, paid once.
  """
  @spec tenant_for_build(Ecto.UUID.t()) :: %{
          org_id: Ecto.UUID.t() | nil,
          pipeline_id: Ecto.UUID.t() | nil
        }
  def tenant_for_build(build_id) do
    Harmont.Repo.one(
      from(b in Build,
        left_join: p in assoc(b, :pipeline),
        where: b.id == ^build_id,
        select: %{org_id: p.organization_id, pipeline_id: p.id}
      )
    ) || %{org_id: nil, pipeline_id: nil}
  end

  @doc """
  The disk snapshot of this job's `builds_in` parent, or nil for a root step.
  Public only so it is unit-testable; called from `start_session/3`.
  """
  @spec parent_snapshot_id(Job.t()) :: String.t() | nil
  def parent_snapshot_id(%Job{builds_in: nil}), do: nil

  def parent_snapshot_id(%Job{builds_in: parent_key, build_id: build_id}) do
    Harmont.Repo.one(
      from(j in Job,
        where: j.build_id == ^build_id and j.step_key == ^parent_key,
        select: j.snapshot_id
      )
    )
  end

  @doc "Enqueue a single runner (Oban-unique by job_id; safe to call twice)."
  def enqueue_runner(%Job{} = job, token) do
    Oban.insert(runner_changeset(job, token))
  end

  @doc """
  Enqueue runners for the root jobs of a freshly-materialized build (pending
  jobs with no prerequisites), threading the raw runner token through args.
  """
  @spec start_build(Ecto.UUID.t(), String.t() | nil) :: :ok
  def start_build(build_id, token) do
    build = Harmont.Repo.get!(Build, build_id)

    roots =
      Harmont.Repo.all(
        from(j in Job,
          where: j.build_id == ^build_id and j.state == "pending",
          left_join: d in JobDep,
          on: d.dependent_id == j.id,
          where: is_nil(d.id),
          distinct: true
        )
      )

    for j <- roots do
      {:ok, _} = Transition.apply(j.id, :ready_to_schedule)
      {:ok, _} = enqueue_runner(j, token)
    end

    maybe_enqueue_build_deadline(build, token)
    :ok
  end

  # The whole-build wall-clock backstop: one ReconcileBuild scheduled at
  # `build.timeout_ms` after start. No timeout configured → nothing to enforce.
  defp maybe_enqueue_build_deadline(%Build{timeout_ms: nil}, _token), do: :ok

  defp maybe_enqueue_build_deadline(%Build{timeout_ms: ms} = build, token) do
    {:ok, _} =
      %{"build_id" => build.id, "token" => token}
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      |> Harmont.Engine.CI.ReconcileBuild.new(
        schedule_in: div(ms, 1000),
        # org_id/build_id in meta (not encrypted args) — see CI.meta/1; uniqueness
        # keys off meta.build_id since there is no single job here.
        meta: %{build_id: build.id, org_id: org_id_for_build(build.id)}
      )
      |> Oban.insert()

    :ok
  end
end

defmodule Harmont.Engine.CI.JobRunner do
  @moduledoc """
  Durable per-job runner. On each `process`:

    * if the job is already terminal → `Advance.after_job` (idempotent) → `:ok`.
    * otherwise → idempotently start the `Session` (which holds the VM + agent
      WebSocket and drives the job to terminal), enqueue ONE `CI.ReconcileJob`
      scheduled at `now + max_runtime` as the durable backstop, and return `:ok`.

  We deliberately do NOT snooze: snoozing against `max_attempts` discards long
  jobs and busy-writes `oban_jobs`. The Session is the prompt path to
  `Advance.after_job`; `CI.ReconcileJob` recovers if the node/Session dies.

  This is an `Oban.Pro.Worker` with **encrypted args** (Task 8): the raw runner
  token rides in `args` and is encrypted at rest in `oban_jobs.args`. Because the
  whole args map is encrypted with a fresh IV each insert, args can't be matched
  by `unique:` — so uniqueness is keyed off `meta.job_id` (`fields: [:meta, ...]`,
  `keys: [:job_id]`), which Pro keeps as plaintext. Inside `process/1` the args
  arrive already decrypted.
  """
  use Oban.Pro.Worker,
    queue: :ci,
    max_attempts: 3,
    encrypted: [key: {Application, :fetch_env!, [:harmont_core, :oban_encryption_key]}],
    unique: [
      fields: [:meta, :queue, :worker],
      keys: [:job_id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias Harmont.Builds.Job
  alias Harmont.Engine.{Advance, ReconcileSupport, SessionSupervisor}
  alias Harmont.Engine.Fsm.JobState

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"job_id" => id} = args}) do
    token = args["token"]
    job = Harmont.Repo.get!(Job, id)

    # Capture the OTel context set by OpentelemetryOban (enqueue→execute link) so
    # we can propagate it into the Session gen_statem, which lives in a different process.
    otel_ctx = OpenTelemetry.Ctx.get_current()

    case JobState.cast(job.state) do
      {:ok, state} ->
        if JobState.terminal?(state) do
          Advance.after_job(id, token)
          :ok
        else
          start_session(job, token, otel_ctx)
        end

      :error ->
        # Unknown/rolling-deploy state: treat as non-terminal, log, and start the
        # session so the backstop still fires. Never raise inside the worker.
        require Logger
        Logger.warning("CI.JobRunner: unknown job state #{inspect(job.state)} for #{id}")
        start_session(job, token, otel_ctx)
    end
  end

  defp start_session(%Job{} = job, token, otel_ctx) do
    _ =
      SessionSupervisor.start_session(
        job_id: job.id,
        build_id: job.build_id,
        # FQN (not `alias`): the public resolver lives on the parent CI module.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        parent_snapshot: Harmont.Engine.CI.parent_snapshot_id(job),
        api_url: api_url(),
        token: token,
        use_agent: use_agent?(),
        otel_ctx: otel_ctx
      )

    {:ok, _} = ReconcileSupport.enqueue(job, token)
    :ok
  end

  defp use_agent?, do: Application.get_env(:harmont_engine, :use_agent, true)
  defp api_url, do: Application.get_env(:harmont_engine, :agent_ws_url, "http://localhost:4000")
end

defmodule Harmont.Engine.ReconcileSupport do
  @moduledoc false
  # Shared helper so JobRunner can enqueue a ReconcileJob without a compile cycle
  # on the worker module. Max runtime = the job's timeout plus generous slack.
  alias Harmont.Builds.Job

  @slack_ms :timer.minutes(2)

  def enqueue(%Job{} = job, token) do
    deadline_ms = (job.timeout_ms || :timer.hours(1)) + @slack_ms

    # FQNs (not `alias`) on purpose: aliasing CI/ReconcileJob here would add a
    # compile-time dependency back onto the worker module this helper exists to
    # decouple from (see @moduledoc). credo:disable the AliasUsage hints for both.
    %{"job_id" => job.id, "build_id" => job.build_id, "token" => token}
    # credo:disable-for-next-line Credo.Check.Design.AliasUsage
    |> Harmont.Engine.CI.ReconcileJob.new(
      schedule_in: div(deadline_ms, 1000),
      # org_id in meta (not args) for the same reasons as the runner — see CI.meta/1.
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      meta: Harmont.Engine.CI.meta(job)
    )
    |> Oban.insert()
  end
end

defmodule Harmont.Engine.CI.ReconcileJob do
  @moduledoc """
  Durable backstop, fired once at a job's deadline (replaces the snooze loop AND
  the deleted OrphanReaper):

    * terminal job → `:ok`.
    * non-terminal + a live `Session` (Registry lookup) → just slow; reschedule
      once more (a single rare timer, not a hot loop).
    * non-terminal + NO live Session → the VM/Session was lost; transition
      `sandbox_lost` then `Advance.after_job` (recovery).

  On node death the Session dies but this job (state `scheduled`) is dispatched
  by the surviving node at its deadline.

  Like `CI.JobRunner`, this is an `Oban.Pro.Worker` with **encrypted args** (Task
  8): the runner token is encrypted at rest in `args`, so uniqueness is keyed off
  `meta.job_id` rather than args. Args arrive decrypted inside `process/1`.
  """
  use Oban.Pro.Worker,
    queue: :ci,
    max_attempts: 3,
    encrypted: [key: {Application, :fetch_env!, [:harmont_core, :oban_encryption_key]}],
    unique: [
      fields: [:meta, :queue, :worker],
      keys: [:job_id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  require OpenTelemetry.Tracer, as: Tracer
  alias Harmont.Builds.Job
  alias Harmont.Engine.{Advance, Transition}
  alias Harmont.Engine.Fsm.JobState

  # A live Session may still be making progress. We only trust it while the agent
  # is beating: a Session alive-but-wedged (its agent dead) must NOT snooze
  # forever. Sits behind the in-Session watchdog (@heartbeat_deadline_ms 30s).
  @default_heartbeat_grace_ms 90_000

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"job_id" => id} = args, attempt: attempt, meta: meta}) do
    token = args["token"]
    job = Harmont.Repo.get!(Job, id)
    now = DateTime.utc_now()

    Tracer.set_attribute("job.state", job.state)
    # Tenant + build identity so a wedged build is sliceable by org/pipeline in
    # Honeycomb (the 2026-06-10 investigation could only see the reconcile job
    # "succeeding" — never which build/org it belonged to). `meta` is JSON-decoded
    # at read time, so its keys are strings, not the atoms `CI.meta/1` inserted.
    if build_id = args["build_id"], do: Tracer.set_attribute("harmont.build.id", build_id)
    if org_id = meta["org_id"], do: Tracer.set_attribute("harmont.org.id", org_id)

    case JobState.cast(job.state) do
      {:ok, state} ->
        cond do
          JobState.terminal?(state) ->
            Tracer.set_attribute("reconcile.outcome", "already_terminal")
            :ok

          session_alive?(id) and heartbeat_fresh?(job, now) ->
            Tracer.set_attribute("reconcile.outcome", "snooze")
            Tracer.set_attribute("session.heartbeat_age_ms", heartbeat_age_ms(job, now))
            # A countable per-snooze event: `attempt` increments on each {:snooze, _},
            # so BubbleUp on this event surfaces a build that has snoozed N times —
            # the signature of the infinite-snooze wedge, previously invisible.
            Tracer.add_event("reconcile.snooze", %{"reconcile.attempt" => attempt})
            {:snooze, 60}

          true ->
            Tracer.set_attribute("reconcile.outcome", "sandbox_lost")
            Tracer.set_attribute("session.alive", session_alive?(id))
            Tracer.set_attribute("session.heartbeat_age_ms", heartbeat_age_ms(job, now))
            force_lost(id, token)
        end

      :error ->
        Tracer.set_attribute("reconcile.outcome", "unknown_state")
        :ok
    end
  end

  # Drive the job terminal and advance the DAG. Tolerant of an illegal arc:
  # Transition.apply returns {:ok|:noop|:error}; a {:noop, _} (e.g. the job was
  # never assigned a sandbox, so :sandbox_lost is illegal) must NOT crash the
  # worker — Advance still recomputes the build off whatever state is current.
  defp force_lost(job_id, token) do
    _ =
      Transition.apply(job_id, :sandbox_lost,
        error_code: "sandbox_lost",
        error_message: "no live/heartbeating session at deadline"
      )

    Advance.after_job(job_id, token)
    :ok
  end

  # Fresh = a heartbeat (or, before the first beat, the start) within the grace.
  # A job with no started_at and no heartbeat hasn't run yet → treat as fresh so
  # we don't kill a job whose Session is still spinning up.
  defp heartbeat_fresh?(%Job{} = job, now) do
    case reference_time(job) do
      nil -> true
      ref -> DateTime.diff(now, ref, :millisecond) < heartbeat_grace_ms()
    end
  end

  defp heartbeat_age_ms(%Job{} = job, now) do
    case reference_time(job) do
      # -1 sentinel: the job never beat (and never started) — distinct from a
      # genuinely-zero-age fresh beat.
      nil -> -1
      ref -> DateTime.diff(now, ref, :millisecond)
    end
  end

  defp reference_time(%Job{last_heartbeat_at: hb, started_at: started}), do: hb || started

  defp heartbeat_grace_ms do
    Application.get_env(
      :harmont_engine,
      :reconcile_heartbeat_grace_ms,
      @default_heartbeat_grace_ms
    )
  end

  defp session_alive?(job_id) do
    case Registry.lookup(Harmont.Engine.SessionRegistry, job_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end
end

defmodule Harmont.Engine.CI.ReconcileBuild do
  @moduledoc """
  Whole-build wall-clock backstop, fired once at `build.timeout_ms` after the
  build starts (enqueued by `CI.start_build/2`). Terminal build → `:ok`;
  otherwise `Harmont.Engine.Timeout.expire/2` drives unfinished jobs to
  `:timed_out` and the build to `:failed`.

  Encrypted args like the other `:ci` workers; uniqueness keys off
  `meta.build_id` (there is no single job here).
  """
  use Oban.Pro.Worker,
    queue: :ci,
    max_attempts: 3,
    encrypted: [key: {Application, :fetch_env!, [:harmont_core, :oban_encryption_key]}],
    unique: [
      fields: [:meta, :queue, :worker],
      keys: [:build_id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias Harmont.Engine.Timeout

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"build_id" => build_id} = args}) do
    Timeout.expire(build_id, args["token"])
  end
end
