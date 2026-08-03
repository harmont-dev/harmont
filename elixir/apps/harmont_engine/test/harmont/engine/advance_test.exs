defmodule Harmont.Engine.AdvanceTest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Builds.Job
  alias Harmont.Engine.{Advance, CI, MaterializeFixture}
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  # a -> b (b builds_in a), via a wait barrier.
  defp materialize_chain(opts \\ []) do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %CommandStep{key: "a", cmd: "echo a"},
          {:wait, false},
          %CommandStep{key: "b", cmd: "echo b", builds_in: "a"}
        ]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Keyword.get(opts, :ext, Ecto.UUID.generate()),
        source_url: "http://x",
        runner_token: "tok"
      )

    build
  end

  defp job(build, key),
    do: Repo.one!(from(j in Job, where: j.build_id == ^build.id and j.step_key == ^key))

  defp set_state!(job, state), do: job |> Job.changeset(%{state: state}) |> Repo.update!()
  defp reload(j), do: Repo.get!(Job, j.id)

  test "enqueues a CI.JobRunner for a newly-ready dependent when a prerequisite passes" do
    build = materialize_chain()
    a = job(build, "a")
    b = job(build, "b")

    # a finished passing; b is still pending and its only prereq (a) is satisfied.
    set_state!(a, "passed")

    assert :ok == Advance.after_job(a.id, "tok")

    # b transitioned to scheduled and a runner was enqueued. The runner's args
    # (including the token) are encrypted at rest, so match on meta.job_id — the
    # plaintext dedupe key — instead of args. The token's delivery is covered by
    # CIIntegrationTest (decrypt -> Session).
    assert reload(b).state == "scheduled"
    assert_enqueued(worker: CI.JobRunner, meta: %{"job_id" => b.id})
  end

  test "schedules a newly-ready dependent and broadcasts its :scheduled state post-commit" do
    ext = Ecto.UUID.generate()
    build = materialize_chain(ext: ext)
    a = job(build, "a")
    b = job(build, "b")

    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    set_state!(a, "passed")
    assert :ok == Advance.after_job(a.id, "tok")

    # The pending -> scheduled write and the runner enqueue commit together (one
    # Ecto.Multi), so a scheduled job always has a runner. We also emit the
    # job-state broadcast for the scheduled job (it bypasses Transition.apply now).
    assert reload(b).state == "scheduled"
    # Runner args are encrypted; match the plaintext dedupe key in meta.
    assert_enqueued(worker: CI.JobRunner, meta: %{"job_id" => b.id})
    assert_received {:job_state, ^ext, %{step_key: "b", state: :scheduled}}
  end

  test "cascade-skips a dependent when its prerequisite fails" do
    build = materialize_chain()
    a = job(build, "a")
    b = job(build, "b")

    set_state!(a, "failed")

    assert :ok == Advance.after_job(a.id, "tok")

    assert reload(b).state == "skipped"
    # no runner for a skipped job (match on meta — runner args are encrypted)
    refute_enqueued(worker: CI.JobRunner, meta: %{"job_id" => b.id})
  end

  test "broadcasts {:job_state, ext, skipped} for a cascade-skipped dependent" do
    ext = Ecto.UUID.generate()
    build = materialize_chain(ext: ext)
    a = job(build, "a")
    b = job(build, "b")

    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    set_state!(a, "failed")
    assert :ok == Advance.after_job(a.id, "tok")

    assert reload(b).state == "skipped"
    # the cascade-skip path bypasses Transition.apply, so Advance must emit it
    assert_received {:job_state, ^ext, %{step_key: "b", state: :skipped}}
  end

  test "persists the build aggregate and broadcasts state + terminal on PubSub" do
    ext = Ecto.UUID.generate()
    build = materialize_chain(ext: ext)
    a = job(build, "a")
    b = job(build, "b")

    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    # Drive both jobs to a terminal state so the build aggregate is terminal.
    set_state!(a, "passed")
    set_state!(b, "passed")

    assert :ok == Advance.after_job(b.id, "tok")

    assert Repo.get!(Harmont.Builds.Build, build.id).state == "passed"
    assert_received {:build_state, ^ext, :passed}
    assert_received {:build_terminal, ^ext, :passed}
  end

  test "intermediate (non-terminal) build broadcasts state but not terminal" do
    ext = Ecto.UUID.generate()
    build = materialize_chain(ext: ext)
    a = job(build, "a")

    Phoenix.PubSub.subscribe(Harmont.PubSub, "build:#{ext}")

    set_state!(a, "passed")
    assert :ok == Advance.after_job(a.id, "tok")

    # build is still running (b just got scheduled / running)
    assert Repo.get!(Harmont.Builds.Build, build.id).state in ~w(running scheduled)
    assert_received {:build_state, ^ext, _}
    refute_received {:build_terminal, ^ext, _}
  end
end
