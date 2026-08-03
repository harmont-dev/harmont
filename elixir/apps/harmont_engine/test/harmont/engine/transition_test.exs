defmodule Harmont.Engine.TransitionTest do
  use Harmont.DataCase, async: true
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Transition
  alias Harmont.Repo

  setup do
    ext = Ecto.UUID.generate()

    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: ext})
      |> Repo.insert()

    {:ok, job} =
      %Job{}
      |> Job.changeset(%{build_id: build.id, step_key: "a", command: "x", state: "pending"})
      |> Repo.insert()

    %{job: job, ext: ext}
  end

  test "applies a legal transition and persists new state", %{job: job} do
    assert {:ok, %Job{state: "scheduled"}} = Transition.apply(job.id, :ready_to_schedule)
  end

  test "drops an illegal transition, leaving state unchanged", %{job: job} do
    assert {:noop, %Job{state: "pending"}} = Transition.apply(job.id, :reported_passed)
  end

  test "sets started_at on -> running and finished_at on terminal", %{job: job} do
    {:ok, _} = Transition.apply(job.id, :ready_to_schedule)
    {:ok, _} = Transition.apply(job.id, :assigned_to_sandbox)
    {:ok, running} = Transition.apply(job.id, :started)
    assert running.started_at != nil
    {:ok, passed} = Transition.apply(job.id, :reported_passed)
    assert passed.finished_at != nil
  end

  test "broadcasts {:job_state, ext, payload} for the running transition", %{job: job, ext: ext} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    {:ok, _} = Transition.apply(job.id, :ready_to_schedule)
    {:ok, _} = Transition.apply(job.id, :assigned_to_sandbox)
    {:ok, _} = Transition.apply(job.id, :started)

    assert_received {:job_state, ^ext, %{step_key: "a", state: :running}}
  end

  test "broadcasts a terminal failure with exit_code + error detail", %{job: job, ext: ext} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    {:ok, _} = Transition.apply(job.id, :ready_to_schedule)
    {:ok, _} = Transition.apply(job.id, :assigned_to_sandbox)
    {:ok, _} = Transition.apply(job.id, :started)

    {:ok, _} =
      Transition.apply(job.id, :reported_failed,
        exit_code: 17,
        error_code: "command_failed",
        error_message: "boom"
      )

    # The payload carries the internal job-state atom (:failed); the relay maps
    # it to the proto JobState enum (:JOB_FAILED), which Mirror.jobStateOf accepts.
    assert_received {:job_state, ^ext,
                     %{
                       step_key: "a",
                       state: :failed,
                       exit_code: 17,
                       error_code: "command_failed",
                       error_message: "boom"
                     }}
  end

  test "does not broadcast for a dropped (illegal) transition", %{job: job, ext: ext} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    assert {:noop, _} = Transition.apply(job.id, :reported_passed)
    refute_received {:job_state, ^ext, _}
  end
end
