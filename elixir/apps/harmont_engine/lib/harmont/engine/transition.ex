defmodule Harmont.Engine.Transition do
  @moduledoc """
  A *transition* is one move of a job through its finite-state machine
  (`pending → scheduled → assigned → running → {passed | failed | canceled |
  skipped | timed_out | ...}`), as defined by
  `Harmont.Engine.Fsm.JobState.transition/2`. `apply/3` is the persistence
  wrapper around that FSM: it loads the job `FOR UPDATE`, asks the FSM for the
  next state given an event, persists the result, and broadcasts it. Illegal
  arcs the FSM rejects become `{:noop, job}` — they never crash.

  Persist a single job transition atomically. Port of
  Worker/Transition.applyTransitionDB: load -> Engine.transition -> update.
  Illegal arcs are dropped (returns {:noop, job}); they never crash.

  On a successful (committed) transition we broadcast a `{:job_state, ext,
  payload}` PubSub message to `"build:\#{ext}"` for in-process subscribers (e.g.
  the gh_app Reporter, which drives Check Runs off these events). The broadcast
  fires AFTER the transaction commits (the `Harmont.Repo.transaction` has
  returned), so the row a subscriber observes is the row it will see on its own
  read. The payload carries the internal job-state *atom* (e.g. `:running`).
  """
  import Ecto.Query
  require Logger
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Fsm.JobState
  alias Harmont.Engine.Metering

  @spec apply(Ecto.UUID.t(), JobState.event(), keyword()) ::
          {:ok, Job.t()} | {:noop, Job.t()} | {:error, term()}
  def apply(job_id, event, extra \\ []) do
    Harmont.Repo.transaction(fn ->
      job = Harmont.Repo.one!(from(j in Job, where: j.id == ^job_id, lock: "FOR UPDATE"))

      case JobState.transition(JobState.cast!(job.state), event) do
        {:ok, new_state} ->
          job
          |> Job.changeset(state_attrs(new_state, extra))
          |> Harmont.Repo.update!()
          |> then(&{:applied, &1})

        :error ->
          {:dropped, job}
      end
    end)
    |> case do
      {:ok, {:applied, job}} ->
        broadcast_job_state(job)
        meter_if_terminal(job)
        {:ok, job}

      {:ok, {:dropped, job}} ->
        {:noop, job}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc """
  Broadcast a `{:job_state, ext, payload}` message for a job row (post-commit).

  Shared with `Harmont.Engine.Advance`, whose cascade-skip path writes
  `state: "skipped"` directly (bypassing `apply/3`) and must still notify the
  mirror. `ext` is the build's `external_build_id` — the same value used as the
  PubSub topic and the proto `external_build_id` field.
  """
  @spec broadcast_job_state(Job.t()) :: :ok
  def broadcast_job_state(%Job{} = job) do
    ext =
      Harmont.Repo.one(
        from(b in Build, where: b.id == ^job.build_id, select: b.external_build_id)
      )

    # Carry the internal job-state atom (not the DB string) over PubSub for
    # in-process subscribers on "build:<ext>" (e.g. the gh_app Reporter).
    payload = %{
      step_key: job.step_key,
      state: JobState.cast!(job.state),
      exit_code: job.exit_code,
      error_message: job.error_message,
      error_code: job.error_code
    }

    :ok =
      Phoenix.PubSub.broadcast(
        Harmont.PubSub,
        "build:#{ext}",
        {:job_state, ext, payload}
      )
  end

  # Bill the VM lease for a job that just reached a terminal state. Runs
  # post-commit and best-effort: a billing failure is logged, never raised, so
  # it can never turn a real job completion into an error. Metering itself is a
  # no-op for jobs that ran no VM or have no org. Idempotent on job_id.
  defp meter_if_terminal(%Job{} = job) do
    if JobState.terminal?(JobState.cast!(job.state)) do
      try do
        Metering.meter_finished_job(job, Harmont.Repo)
      rescue
        # Intentionally broad: this also swallows programmer errors in metering,
        # not just DB write failures. That tradeoff is deliberate — nothing in
        # billing may break a job's completion. Do NOT narrow this to specific
        # exceptions; log-and-continue is the whole point.
        e ->
          Logger.error("vm-lease metering failed for job #{job.id}: #{Exception.message(e)}")
      end
    end

    :ok
  end

  defp state_attrs(new_state, extra) do
    base = %{state: Atom.to_string(new_state)}

    base =
      case new_state do
        :running ->
          Map.put(base, :started_at, DateTime.utc_now())

        s ->
          if JobState.terminal?(s),
            do: Map.put(base, :finished_at, DateTime.utc_now()),
            else: base
      end

    Enum.into(extra, base)
  end
end
