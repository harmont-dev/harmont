defmodule Harmont.Engine.CIIntegrationTest do
  @moduledoc """
  End-to-end happy path in Local mode: materialize a 2-job build (a, then wait,
  then b builds_in a), `CI.start_build`, and drive the async Sessions + follow-on
  Oban JobRunners to completion deterministically.
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{CI, MaterializeFixture}
  alias Harmont.Engine.CI.JobRunner
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  setup do
    # Sessions run in DynamicSupervisor-spawned processes that need to see this
    # test's transaction: share the sandbox connection.
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp build_2_job do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %CommandStep{key: "a", cmd: "true"},
          {:wait, false},
          %CommandStep{key: "b", cmd: "true", builds_in: "a"}
        ]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    build
  end

  defp job(build, key),
    do: Repo.one!(from(j in Job, where: j.build_id == ^build.id and j.step_key == ^key))

  # Drive the system to quiescence: drain enqueued CI JobRunners (which start
  # async Sessions), give the Sessions a beat to advance + enqueue dependents,
  # then drain again — repeat until the build is terminal or we time out.
  defp run_to_terminal(build_id, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      Oban.drain_queue(queue: :ci, with_recursion: true, with_safety: false)
      Process.sleep(20)

      case Repo.get!(Build, build_id).state do
        s when s in ~w(passed failed canceled) -> {:halt, s}
        _ -> {:cont, nil}
      end
    end)
  end

  test "a -> b chain runs to a passed build with both jobs passed" do
    build = build_2_job()

    assert :ok == CI.start_build(build.id, "tok")
    # Runner args are encrypted; assert on the plaintext meta.job_id. The token's
    # decryption-into-Session path is what run_to_terminal/1 below exercises.
    assert_enqueued(worker: JobRunner, meta: %{"job_id" => job(build, "a").id})

    assert "passed" == run_to_terminal(build.id)

    assert Repo.get!(Build, build.id).state == "passed"
    assert job(build, "a").state == "passed"
    assert job(build, "b").state == "passed"
  end

  test "a fails -> b is skipped and the build fails" do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [
          %CommandStep{key: "a", cmd: "exit 1"},
          {:wait, false},
          %CommandStep{key: "b", cmd: "true", builds_in: "a"}
        ]
      })

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    assert :ok == CI.start_build(build.id, "tok")
    assert "failed" == run_to_terminal(build.id)

    assert job(build, "a").state == "failed"
    assert job(build, "b").state == "skipped"
  end
end
