defmodule Harmont.Engine.TimeoutTest do
  @moduledoc """
  Tests for `Harmont.Engine.Timeout.expire/2`.
  Oban is `:manual` in test so `Oban.cancel_all_jobs` is a no-op on an empty
  queue — fine, we only need to assert DB state transitions.
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Timeout
  alias Harmont.Repo

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Seed a build (timeout_ms set) plus one Job per entry in `job_states`.
  # Returns {build, jobs} with jobs in the same order as the given states.
  defp seed(job_states) do
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{
        external_build_id: Ecto.UUID.generate(),
        state: "running",
        timeout_ms: 600_000
      })
      |> Repo.insert()

    jobs =
      for {st, i} <- Enum.with_index(job_states) do
        {:ok, job} =
          %Job{}
          |> Job.changeset(%{
            build_id: build.id,
            step_key: "step_#{i}",
            command: "x",
            state: Atom.to_string(st)
          })
          |> Repo.insert()

        job
      end

    {build, jobs}
  end

  defp state(job_id),
    do: Repo.one!(from(j in Job, where: j.id == ^job_id, select: j.state))

  test "expire/2 times out non-terminal jobs and fails the build" do
    {build, [running, pending, passed]} = seed([:running, :pending, :passed])

    assert :ok = Timeout.expire(build.id, nil)

    assert state(running.id) == "timed_out"
    assert state(pending.id) == "timed_out"
    # already-terminal untouched
    assert state(passed.id) == "passed"

    build = Repo.get!(Build, build.id)
    assert build.state == "failed"
    assert build.error_code == "pipeline_timeout"
    refute is_nil(build.finished_at)
  end

  test "expire/2 is a no-op on an already-terminal build" do
    {build, _} = seed([:passed])
    Repo.update!(Build.changeset(build, %{state: "passed"}))
    assert :ok = Timeout.expire(build.id, nil)
    assert Repo.get!(Build, build.id).state == "passed"
  end

  test "expire/2 is a no-op on a missing build" do
    assert :ok = Timeout.expire(Ecto.UUID.generate(), nil)
  end
end
