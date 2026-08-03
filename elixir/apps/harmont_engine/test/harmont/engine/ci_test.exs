defmodule Harmont.Engine.CITest do
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{CI, Materialize, MaterializeFixture, ReconcileSupport}
  alias Harmont.Engine.CI.{JobRunner, ReconcileJob}
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  setup do
    # The JobRunner spawns a Session under the DynamicSupervisor; share the
    # sandbox connection so the spawned process sees this transaction.
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp materialize_chain do
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

  # Build a single-command graph materialised onto a build that belongs to an
  # org (via its pipeline), returning {build, org_id}.
  defp build_with_org do
    org =
      Repo.insert!(
        Organization.changeset(%Organization{}, %{
          name: "Acme",
          slug: "acme-#{System.unique_integer([:positive])}"
        })
      )

    pipeline =
      Repo.insert!(
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "p",
          slug: "p-#{System.unique_integer([:positive])}",
          repository: "acme/p",
          default_branch: "main"
        })
      )

    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [%CommandStep{key: "a", cmd: "true"}]
      })

    build =
      Repo.insert!(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          state: "scheduled",
          pipeline_id: pipeline.id
        })
      )

    {:ok, build} = Materialize.materialize_jobs(build, g, runner_token: "tok")
    {build, org.id}
  end

  defp job(build, key),
    do: Repo.one!(from(j in Job, where: j.build_id == ^build.id and j.step_key == ^key))

  test "start_build enqueues runners only for root jobs, threading the token" do
    build = materialize_chain()
    a = job(build, "a")
    b = job(build, "b")

    assert :ok == CI.start_build(build.id, "tok")

    # a is a root (no prereqs) -> scheduled + runner; b depends on a -> not yet.
    assert Repo.get!(Job, a.id).state == "scheduled"

    # Runner args (job_id/build_id/token) are encrypted at rest, so match on the
    # plaintext dedupe key in meta instead of args.
    assert_enqueued(worker: JobRunner, meta: %{"job_id" => a.id})

    refute_enqueued(worker: JobRunner, meta: %{"job_id" => b.id})
  end

  test "enqueue_runner carries the build's org_id in the runner's meta" do
    {build, org_id} = build_with_org()
    a = job(build, "a")

    {:ok, _} = CI.enqueue_runner(a, "tok")

    assert_enqueued(worker: JobRunner, meta: %{"org_id" => org_id})
  end

  test "ReconcileSupport.enqueue carries the build's org_id in the ReconcileJob meta" do
    {build, org_id} = build_with_org()
    a = job(build, "a")

    {:ok, _} = ReconcileSupport.enqueue(a, "tok")

    assert_enqueued(worker: ReconcileJob, meta: %{"org_id" => org_id})
  end

  test "JobRunner for an already-terminal job advances and returns :ok" do
    build = materialize_chain()
    a = job(build, "a")
    a |> Job.changeset(%{state: "passed"}) |> Repo.update!()

    assert :ok ==
             perform_job(JobRunner, %{"job_id" => a.id, "build_id" => build.id, "token" => "tok"})

    # advancing past a passed root schedules the dependent b
    assert Repo.get!(Job, job(build, "b").id).state == "scheduled"
    assert_enqueued(worker: JobRunner, meta: %{"job_id" => job(build, "b").id})
  end

  test "JobRunner for a pending/scheduled job starts a Session and enqueues a ReconcileJob backstop" do
    build = materialize_chain()
    a = job(build, "a")
    # mark scheduled (as start_build would) so the runner takes the non-terminal branch
    a |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             perform_job(JobRunner, %{"job_id" => a.id, "build_id" => build.id, "token" => "tok"})

    # A ReconcileJob backstop must be enqueued immediately (encrypted args -> meta).
    assert_enqueued(worker: ReconcileJob, meta: %{"job_id" => a.id})

    # The Session runs out-of-band in Local mode; wait for it to drive the job to
    # terminal so it doesn't outlive the test transaction (and to prove it works).
    assert_eventually(fn -> Repo.get!(Job, a.id).state == "passed" end)
  end

  test "ReconcileJob marks a stuck non-terminal job sandbox_lost when no Session is alive" do
    build = materialize_chain()
    a = job(build, "a")
    # job stuck in :running with no live Session (e.g. node died mid-job)
    a |> Job.changeset(%{state: "running", started_at: DateTime.utc_now()}) |> Repo.update!()

    assert :ok ==
             perform_job(ReconcileJob, %{
               "job_id" => a.id,
               "build_id" => build.id,
               "token" => "tok"
             })

    # running + sandbox_lost -> failed (terminal), then Advance ran
    reloaded = Repo.get!(Job, a.id)
    assert reloaded.state == "failed"
    assert reloaded.error_code == "sandbox_lost"
    # the build failure cascade-skipped b
    assert Repo.get!(Job, job(build, "b").id).state == "skipped"
  end

  test "ReconcileJob snoozes when a live Session is still registered for the job" do
    build = materialize_chain()
    a = job(build, "a")
    a |> Job.changeset(%{state: "running", started_at: DateTime.utc_now()}) |> Repo.update!()

    # Register a stand-in process under the SessionRegistry keyed by job_id so
    # ReconcileJob's session_alive? lookup succeeds and it takes the snooze arm.
    test_pid = self()

    {:ok, _stub} =
      Task.start_link(fn ->
        {:ok, _} = Registry.register(Harmont.Engine.SessionRegistry, a.id, nil)
        send(test_pid, :registered)
        receive(do: (:stop -> :ok))
      end)

    assert_receive :registered, 1_000

    assert {:snooze, _} =
             perform_job(ReconcileJob, %{
               "job_id" => a.id,
               "build_id" => build.id,
               "token" => "tok"
             })

    # The job is untouched: the live Session still owns it.
    assert Repo.get!(Job, a.id).state == "running"
  end

  test "ReconcileJob for an already-terminal job is a no-op" do
    build = materialize_chain()
    a = job(build, "a")
    a |> Job.changeset(%{state: "passed"}) |> Repo.update!()

    assert :ok ==
             perform_job(ReconcileJob, %{
               "job_id" => a.id,
               "build_id" => build.id,
               "token" => "tok"
             })

    assert Repo.get!(Job, a.id).state == "passed"
  end

  defp assert_eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      if fun.(),
        do: {:halt, :ok},
        else:
          (
            Process.sleep(20)
            {:cont, nil}
          )
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("condition never became true within #{attempts} attempts")
    end
  end
end
