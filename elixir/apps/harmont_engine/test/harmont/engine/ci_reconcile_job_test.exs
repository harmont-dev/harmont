defmodule Harmont.Engine.CIReconcileJobTest do
  @moduledoc """
  Unit tests for the per-job durable backstop `CI.ReconcileJob`. Oban is :manual
  in test, so we call `process/1` directly with plaintext args (args arrive
  already decrypted inside process/1 in production).
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.CI.ReconcileJob
  alias Harmont.Repo

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Seed a build with one job in the given state (+ optional heartbeat/started).
  defp seed(state, attrs \\ %{}) do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "running"})
      |> Repo.insert()

    {:ok, job} =
      %Job{}
      |> Job.changeset(
        Map.merge(
          %{build_id: build.id, step_key: "a", command: "true", state: state},
          attrs
        )
      )
      |> Repo.insert()

    {build, job}
  end

  defp oban_job(job_id), do: %Oban.Job{args: %{"job_id" => job_id, "token" => "tok"}}

  # Register the current process as the job's live Session in the Registry.
  defp register_session(job_id) do
    {:ok, _} = Registry.register(Harmont.Engine.SessionRegistry, job_id, nil)
    :ok
  end

  defp state(job_id), do: Repo.get!(Job, job_id).state

  test "terminal job returns :ok and does nothing" do
    {_b, job} = seed("passed")
    assert :ok == ReconcileJob.process(oban_job(job.id))
    assert state(job.id) == "passed"
  end

  test "live session with a FRESH heartbeat snoozes" do
    {_b, job} = seed("running", %{last_heartbeat_at: DateTime.utc_now()})
    register_session(job.id)
    assert {:snooze, 60} == ReconcileJob.process(oban_job(job.id))
    assert state(job.id) == "running"
  end

  test "live session with a STALE heartbeat is driven terminal (not snoozed forever)" do
    stale = DateTime.add(DateTime.utc_now(), -600, :second)
    {_b, job} = seed("running", %{last_heartbeat_at: stale})
    register_session(job.id)

    assert :ok == ReconcileJob.process(oban_job(job.id))
    assert state(job.id) == "failed"
    assert Repo.get!(Job, job.id).error_code == "sandbox_lost"
  end

  test "no live session drives a running job terminal" do
    {_b, job} = seed("running")
    assert :ok == ReconcileJob.process(oban_job(job.id))
    assert state(job.id) == "failed"
  end

  test "does not crash when sandbox_lost is an illegal arc (regression: was {:ok,_}= match)" do
    # :scheduled does not accept :sandbox_lost; Transition.apply returns {:noop,_}.
    # The old `{:ok, _} =` match crashed here. process/1 must return :ok cleanly.
    {_b, job} = seed("scheduled")
    assert :ok == ReconcileJob.process(oban_job(job.id))
    # State is left untouched by the dropped (illegal) transition.
    assert state(job.id) == "scheduled"
  end
end
