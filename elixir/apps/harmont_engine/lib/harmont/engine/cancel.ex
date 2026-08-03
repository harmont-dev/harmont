defmodule Harmont.Engine.Cancel do
  @moduledoc """
  Cooperative build cancel. Cancel ordering (REVISION 2026-05-24c):

    1. Set `build.cancel_requested` + transition every non-terminal job via
       `:cancel_requested` (pending/scheduled → canceled, assigned/running →
       canceling). This runs first so any later `CI.JobRunner` perform or Session
       sees the terminal/canceling state and does not re-run the job.

    2. `Oban.cancel_all_jobs` for the build's `CI.JobRunner` rows (stops queued /
       snoozing runners). With the snooze loop gone this is a safety net — mostly
       a no-op but important if a runner was re-scheduled and hasn't started yet.

    3. `Session.cancel(job_id)` via `cast_if_alive` for every non-terminal job
       (not only via agent PubSub). A provisioning Session with no agent yet must
       still tear down its VM. Also broadcast `job_cancel:<id>` so the AgentSocket
       can push a cancel frame to an already-connected agent.
  """
  import Ecto.Query
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Fsm.JobState
  alias Harmont.Engine.{Session, Transition}

  @spec request(String.t()) :: boolean()
  def request(external_build_id) do
    case Harmont.Repo.get_by(Build, external_build_id: external_build_id) do
      nil ->
        false

      build ->
        # Step 1: flag the build + transition every non-terminal job.
        build
        |> Build.changeset(%{cancel_requested: true, state: "canceling"})
        |> Harmont.Repo.update!()

        non_terminal =
          Harmont.Repo.all(from(j in Job, where: j.build_id == ^build.id))
          |> Enum.reject(&terminal?/1)

        for job <- non_terminal do
          _ = Transition.apply(job.id, :cancel_requested)
        end

        # Step 2: cancel any queued/snoozing Oban runners AND reconcile-backstops
        # for this build. Their args are encrypted (Task 8), so build_id is no
        # longer queryable in `args` — match `meta->>'build_id'`, which CI.meta/1
        # stores in plaintext for exactly this lookup.
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

        # Step 3: signal live Sessions directly (cast_if_alive, no-ops if gone)
        # and push a cancel frame to any connected agent via PubSub.
        for job <- non_terminal do
          Session.cancel(job.id)
          :ok = Phoenix.PubSub.broadcast(Harmont.PubSub, "job_cancel:#{job.id}", :cancel)
        end

        true
    end
  end

  defp terminal?(job) do
    case JobState.cast(job.state) do
      {:ok, state} -> JobState.terminal?(state)
      # Unknown state on a rolling deploy: treat as non-terminal to be safe.
      :error -> false
    end
  end
end
