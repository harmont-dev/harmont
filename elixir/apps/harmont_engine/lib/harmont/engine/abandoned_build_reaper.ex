defmodule Harmont.Engine.AbandonedBuildReaper do
  @moduledoc """
  Quarter-hourly Oban cron worker. The backstop ABOVE the per-job
  `CI.ReconcileJob`: it forces terminal any build stuck non-terminal past a hard
  deadline whose jobs have NO live `Session` and NO pending Oban runner/reconcile
  — the cases `CI.ReconcileJob` cannot recover (its own job pruned or lost, or
  the `:ci` queue paused during an incident). Driving the build terminal lets
  `Advance.recompute_build/1` fire `reap_snapshots/1`, freeing the leaked fork
  tree.

  Guarded hard: a build is reaped only when ALL of (old enough) AND (no live
  session) AND (no pending Oban job) hold, so a legitimately long-running build
  is never failed. The deadline defaults to 6h, overridable via
  `:harmont_engine, :abandoned_build_deadline_ms`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{Advance, Transition}
  alias Harmont.Engine.Fsm.JobState
  alias Harmont.Repo

  @non_terminal ~w(scheduled running failing canceling)
  @default_deadline_ms :timer.hours(6)

  # Oban states that mean a runner/reconcile is still pending for the build.
  @pending_oban ~w(scheduled available executing retryable suspended)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: sweep(DateTime.utc_now())

  @doc "Reap abandoned builds older than the deadline. Public for testing with an injected `now`."
  @spec sweep(DateTime.t()) :: :ok
  def sweep(now) do
    cutoff = DateTime.add(now, -div(deadline_ms(), 1000), :second)

    stale_build_ids =
      Repo.all(
        from(b in Build,
          where: b.state in ^@non_terminal and b.inserted_at < ^cutoff,
          select: b.id
        )
      )

    for build_id <- stale_build_ids, abandoned?(build_id) do
      fail_build(build_id)
    end

    :ok
  end

  # Abandoned = no live Session for any job AND no pending Oban job for the build.
  defp abandoned?(build_id) do
    not has_live_session?(build_id) and not has_pending_oban_job?(build_id)
  end

  defp has_live_session?(build_id) do
    Repo.all(from(j in Job, where: j.build_id == ^build_id, select: j.id))
    |> Enum.any?(fn job_id ->
      match?([{_pid, _}], Registry.lookup(Harmont.Engine.SessionRegistry, job_id))
    end)
  end

  # CI.JobRunner / CI.ReconcileJob carry build_id in meta (args are encrypted).
  defp has_pending_oban_job?(build_id) do
    Repo.exists?(
      from(o in Oban.Job,
        where:
          fragment("?->>'build_id' = ?", o.meta, ^build_id) and
            o.state in ^@pending_oban
      )
    )
  end

  defp fail_build(build_id) do
    jobs = Repo.all(from(j in Job, where: j.build_id == ^build_id))

    Enum.each(jobs, &terminalise/1)

    # Recompute via the normal DAG step against any job (cascade-skips dependents,
    # rolls up the aggregate, and reaps the fork tree when terminal).
    case jobs do
      [j | _] ->
        Advance.after_job(j.id, nil)

        :telemetry.execute(
          [:harmont, :abandoned_build, :reaped],
          %{count: length(jobs)},
          %{build_id: build_id}
        )

        Logger.warning(
          "abandoned-build reaper failed stuck build #{build_id} (#{length(jobs)} jobs)"
        )

      [] ->
        :ok
    end
  end

  defp terminalise(%Job{} = job) do
    case JobState.cast(job.state) do
      {:ok, state} ->
        cond do
          JobState.terminal?(state) ->
            :ok

          state in ~w(assigned running timing_out canceling)a ->
            Transition.apply(job.id, :sandbox_lost,
              error_code: "build_abandoned",
              error_message: "build exceeded the abandoned-build deadline with no live session"
            )

          state in ~w(pending scheduled)a ->
            Transition.apply(job.id, :cancel_requested)

          true ->
            :ok
        end

      :error ->
        :ok
    end
  end

  defp deadline_ms,
    do: Application.get_env(:harmont_engine, :abandoned_build_deadline_ms, @default_deadline_ms)
end
