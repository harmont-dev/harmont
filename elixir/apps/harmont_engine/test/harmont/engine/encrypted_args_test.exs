defmodule Harmont.Engine.EncryptedArgsTest do
  @moduledoc """
  Task 8: the runner token must never sit in plaintext in `oban_jobs.args`.
  These tests insert through the real Oban path (encryption applies) and read
  the raw row back, so they prove (1) the token is encrypted at rest and (2)
  uniqueness still collapses duplicate runners now that the dedupe key lives in
  `meta` (encrypted args can't be matched by `unique:`).
  """
  use Harmont.DataCase, async: false

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{CI, Materialize}
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  # A single-command graph materialised onto a build that belongs to an org
  # (via its pipeline), so CI.meta/1 can resolve org_id. Mirrors CITest's fixture.
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
    job = Repo.one!(from(j in Job, where: j.build_id == ^build.id and j.step_key == "a"))
    {build, job}
  end

  test "JobRunner does not persist the runner token in plaintext" do
    {_build, job} = build_with_org()
    {:ok, ob} = CI.enqueue_runner(job, "super-secret-token")

    raw = Repo.get!(Oban.Job, ob.id)
    refute Jason.encode!(raw.args) =~ "super-secret-token"
  end

  test "encrypted JobRunner is still unique by job_id (via meta)" do
    {_build, job} = build_with_org()

    {:ok, _} = CI.enqueue_runner(job, "t1")
    # Duplicate by job_id (different token). Uniqueness keyed on meta.job_id must
    # collapse this to the SAME job rather than provisioning a second runner.
    {:ok, _} = CI.enqueue_runner(job, "t2")

    count =
      Repo.aggregate(
        from(o in Oban.Job, where: o.worker == "Harmont.Engine.CI.JobRunner"),
        :count
      )

    assert count == 1
  end

  test "an encrypted runner is still cancellable by build_id (via meta)" do
    {build, job} = build_with_org()
    {:ok, ob} = CI.enqueue_runner(job, "tok")

    # The runner's build_id lives in encrypted args, so the only plaintext handle
    # is meta->>'build_id'. Mirror Cancel.request/1's query and confirm it matches
    # this build's runner (and would NOT match if we keyed off args, which is now
    # ciphertext under args->'data').
    Oban.cancel_all_jobs(
      from(o in Oban.Job,
        where: o.worker == "Harmont.Engine.CI.JobRunner",
        where: fragment("? ->> 'build_id' = ?", o.meta, ^build.id)
      )
    )

    assert Repo.get!(Oban.Job, ob.id).state == "cancelled"
  end
end
