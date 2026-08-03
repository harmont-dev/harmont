defmodule Harmont.Engine.Advance do
  @moduledoc """
  "Recompute the build" means re-deriving the build's single roll-up state — the
  *build aggregate* — from the states of all its jobs: the build is running while
  any job is still live, failed if any job failed, passed once every job passes,
  and so on (see `Harmont.Engine.Fsm.BuildState`). `after_job/2` is the
  idempotent post-job DAG step: given a job that just reached a terminal-ish
  state, it (1) cascade-skips the dependents of failed jobs, (2) schedules and
  enqueues newly-unblocked dependents, and (3) recomputes, persists, and
  broadcasts that build aggregate.

  The idempotent DAG step. Given a job that just reached a terminal-ish state,
  recompute the build: cascade-skip dependents of failures, enqueue runners for
  newly-ready dependents, and persist + broadcast the build aggregate.

  Safe to call from both the `Session` (prompt path) and `CI.ReconcileJob`
  (durable backstop) concurrently: a per-build advisory lock serializes all
  advances for a build (READ COMMITTED would otherwise let two sibling
  completions both miss a shared dependent), and every write is idempotent.

  The raw runner token is threaded through so newly-enqueued runners can launch
  their own agents — it is never persisted in the clear (only hashed on the
  build row).
  """
  import Ecto.Query
  require OpenTelemetry.Tracer, as: Tracer
  alias Harmont.Builds.{Build, Job, JobDep}
  alias Harmont.Engine.{CI, Scheduling, Transition}
  alias Harmont.Engine.Fsm.{BuildState, JobState}
  alias Harmont.Sandboxes

  @spec after_job(Ecto.UUID.t(), String.t() | nil) :: :ok
  def after_job(job_id, token \\ nil) do
    build_id = Harmont.Repo.one!(from(j in Job, where: j.id == ^job_id, select: j.build_id))

    {:ok, {skipped, scheduled}} =
      Harmont.Repo.transaction(fn ->
        # Serialize ALL advances for this build; auto-released on commit/rollback.
        _ = Harmont.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [build_id])

        {jobs, deps} = load(build_id)
        states = Map.new(jobs, &{&1.step_key, JobState.cast!(&1.state)})
        dep_keys = for d <- deps, do: {key(jobs, d.dependent_id), key(jobs, d.prerequisite_id)}

        # Cascade-skip dependents of failures. This path writes "skipped" directly
        # (bypassing Transition.apply), so collect the rows and broadcast their
        # job-state AFTER the transaction commits — same post-commit discipline as
        # the build-aggregate broadcast in recompute_build/1.
        skipped =
          for k <- Scheduling.cascade_skips(states, dep_keys) do
            j = Enum.find(jobs, &(&1.step_key == k))

            j
            |> Job.changeset(%{state: "skipped", finished_at: DateTime.utc_now()})
            |> Harmont.Repo.update!()
          end

        # Schedule + enqueue newly-ready runners. BOTH the pending -> scheduled
        # state write AND the runner insert go into ONE Ecto.Multi so they commit
        # or roll back together: previously the state moved via Transition.apply (a
        # separate nested savepoint that committed at once), so a rollback of the
        # outer advance after that point left the job `scheduled` with no enqueued
        # runner — a permanently stuck job. The runners use Oban.insert/multi (not
        # bare Oban.insert/1, which opens its own connection and would break the
        # advisory-lock serialization); the whole multi runs on this connection as
        # a nested savepoint, so runners become visible only if the advance commits.
        #
        # ready/2 returns only :pending jobs, so the legal arc is always
        # :ready_to_schedule -> :scheduled; we apply the FSM explicitly here rather
        # than re-load FOR UPDATE because the per-build advisory lock above already
        # serializes every advance for this build.
        ready_jobs =
          for k <- Scheduling.ready(states, dep_keys), do: Enum.find(jobs, &(&1.step_key == k))

        multi =
          Enum.reduce(ready_jobs, Ecto.Multi.new(), fn j, multi ->
            {:ok, :scheduled} = JobState.transition(JobState.cast!(j.state), :ready_to_schedule)

            multi
            |> Ecto.Multi.update(
              {:schedule, j.id},
              Job.changeset(j, %{state: "scheduled"})
            )
            |> Oban.insert({:runner, j.id}, CI.runner_changeset(j, token))
          end)

        {:ok, results} = Harmont.Repo.transaction(multi)

        scheduled = for j <- ready_jobs, do: Map.fetch!(results, {:schedule, j.id})

        recompute_build(build_id)
        {skipped, scheduled}
      end)

    # Post-commit: notify the mirror of each job whose state we changed. Done
    # outside the transaction so the relay never observes a state that a rollback
    # would erase. Both cascade-skips and the schedule writes bypass
    # Transition.apply's own broadcast, so we broadcast them here directly.
    for j <- skipped, do: Transition.broadcast_job_state(j)
    for j <- scheduled, do: Transition.broadcast_job_state(j)

    :ok
  end

  defp recompute_build(build_id) do
    build = Harmont.Repo.get!(Build, build_id)
    {jobs, _} = load(build_id)
    job_states = Enum.map(jobs, &JobState.cast!(&1.state))
    agg = BuildState.recompute(job_states, build.cancel_requested)

    finished =
      if agg in ~w(passed failed canceled)a, do: DateTime.utc_now(), else: build.finished_at

    build
    |> Build.changeset(%{state: Atom.to_string(agg), finished_at: finished})
    |> Harmont.Repo.update!()

    # Annotate the active Oban-job span with the computed build state (no-op when
    # OTel SDK is not running or no span is active).
    Tracer.set_attribute("build.state", Atom.to_string(agg))

    ext = build.external_build_id

    # Carry the internal build-aggregate atom (not a string) over PubSub.
    # In-process subscribers on "build:<ext>" (e.g. the gh_app Reporter) consume
    # it directly — there is no longer a gRPC wire boundary to translate at.
    :ok =
      Phoenix.PubSub.broadcast(
        Harmont.PubSub,
        "build:#{ext}",
        {:build_state, ext, agg}
      )

    if agg in ~w(passed failed canceled)a do
      reap_snapshots(build_id)

      :ok =
        Phoenix.PubSub.broadcast(
          Harmont.PubSub,
          "build:#{ext}",
          {:build_terminal, ext, agg}
        )
    end
  end

  @doc """
  Delete every `builds_in` disk snapshot recorded for a finished build.
  Fire-and-forget; a backend that does not implement `delete_snapshot/1` is a
  no-op. Public so it is unit-testable.
  """
  @spec reap_snapshots(Ecto.UUID.t()) :: :ok
  def reap_snapshots(build_id) do
    backend = HarmontVm.Backend.impl()

    if function_exported?(backend, :delete_snapshot, 1) do
      ids =
        Harmont.Repo.all(
          from(j in Job,
            where: j.build_id == ^build_id and not is_nil(j.snapshot_id),
            select: j.snapshot_id
          )
        )

      reap_passes(backend, ids, delete_passes(backend))

      # On a live-VM backend the snapshot_id IS the sandbox id, so the reaped ids
      # are registry external_ids. Flip them to deleted so the SandboxReaper does
      # not re-list them as live. No-op for ids we never recorded.
      provider = HarmontVm.Backend.provider()
      Enum.each(ids, &Sandboxes.mark_deleted(provider, &1))
    end

    :ok
  end

  # Live-VM fork backends (Daytona) build a fork TREE: a parent can't be deleted
  # while it has a live fork child, so we sweep bottom-up over a few passes. Disk-
  # snapshot backends (Runloop) are order-independent — one pass.
  defp delete_passes(backend) do
    if function_exported?(backend, :fork_source_is_live_vm?, 0) and
         backend.fork_source_is_live_vm?(),
       do: 5,
       else: 1
  end

  defp reap_passes(_backend, [], _passes), do: :ok
  defp reap_passes(_backend, _ids, 0), do: :ok

  defp reap_passes(backend, ids, passes) do
    Enum.each(ids, &backend.delete_snapshot/1)
    if passes > 1, do: Process.sleep(reap_pass_interval_ms())
    reap_passes(backend, ids, passes - 1)
  end

  defp reap_pass_interval_ms, do: Application.get_env(:harmont_vm, :reap_pass_interval_ms, 2_000)

  defp load(build_id) do
    jobs = Harmont.Repo.all(from(j in Job, where: j.build_id == ^build_id))
    ids = Enum.map(jobs, & &1.id)
    {jobs, Harmont.Repo.all(from(d in JobDep, where: d.dependent_id in ^ids))}
  end

  defp key(jobs, id), do: Enum.find(jobs, &(&1.id == id)).step_key
end
