defmodule Harmont.Engine.Timeout do
  @moduledoc """
  Whole-build wall-clock budget enforcement. `expire/2` is fired by
  `Harmont.Engine.CI.ReconcileBuild` at `build.timeout_ms` after the build
  starts. It drives every non-terminal job to `:timed_out` (via the
  `:build_timeout` FSM event), stamps `error_code: "pipeline_timeout"` on the
  build, tears down live sessions, and recomputes the build aggregate — which
  folds to `:failed` because timed-out jobs count as failures
  (`Harmont.Engine.Fsm.BuildState`).

  Structurally a sibling of `Harmont.Engine.Cancel.request/1`; the difference
  is timed-out (→ failed) vs cancelled (→ canceled) semantics. We deliberately
  do NOT set `cancel_requested`: that would fold the build to `:canceled`, but a
  blown pipeline budget is a FAILURE.
  """
  import Ecto.Query
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{Advance, Session, Transition}
  alias Harmont.Engine.Fsm.JobState

  @build_terminal ~w(passed failed canceled)

  @spec expire(Ecto.UUID.t(), String.t() | nil) :: :ok
  def expire(build_id, token) do
    case Harmont.Repo.get(Build, build_id) do
      nil ->
        :ok

      %Build{state: s} when s in @build_terminal ->
        :ok

      %Build{} = build ->
        do_expire(build, token)
    end
  end

  defp do_expire(%Build{} = build, token) do
    detail = "build exceeded its pipeline timeout of #{div(build.timeout_ms || 0, 1000)}s"

    # Stamp attribution on the build. NOT the state — `Advance.recompute_build`
    # writes `state` + `finished_at` and casts only those two fields, so it
    # leaves this `error_code`/`error_message` untouched.
    build
    |> Build.changeset(%{error_code: "pipeline_timeout", error_message: detail})
    |> Harmont.Repo.update!()

    non_terminal =
      Harmont.Repo.all(from(j in Job, where: j.build_id == ^build.id))
      |> Enum.reject(&terminal?/1)

    # Cancel any queued/snoozing Oban runners AND reconcile-backstops for this
    # build. Their args are encrypted, so build_id is not queryable in `args` —
    # match `meta->>'build_id'`, the same plaintext lookup `Cancel` uses.
    _ =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker in [
              "Harmont.Engine.CI.JobRunner",
              "Harmont.Engine.CI.ReconcileJob"
            ],
          where: fragment("? ->> 'build_id' = ?", j.meta, ^build.id)
        )
      )

    # Drive every non-terminal job straight to :timed_out, then signal live
    # Sessions (cast_if_alive, no-op if gone) and push a cancel frame to any
    # connected agent via PubSub so VMs/agents tear down.
    for job <- non_terminal do
      _ =
        Transition.apply(job.id, :build_timeout,
          error_code: "pipeline_timeout",
          error_message: detail
        )

      Session.cancel(job.id)
      :ok = Phoenix.PubSub.broadcast(Harmont.PubSub, "job_cancel:#{job.id}", :cancel)
    end

    # Finalize the build aggregate now that all jobs are terminal: recompute
    # folds timed-out jobs to a FAILED build and stamps `finished_at`. If there
    # were no non-terminal jobs, the aggregate was already final — nothing to do.
    case non_terminal do
      [job | _] -> Advance.after_job(job.id, token)
      [] -> :ok
    end

    :ok
  end

  defp terminal?(job) do
    case JobState.cast(job.state) do
      {:ok, state} -> JobState.terminal?(state)
      # Unknown state on a rolling deploy: treat as non-terminal to be safe.
      :error -> false
    end
  end
end
