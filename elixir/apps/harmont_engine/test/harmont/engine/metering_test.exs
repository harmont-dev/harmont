defmodule Harmont.Engine.MeteringTest do
  use Harmont.DataCase, async: true
  import Ecto.Query
  alias Harmont.Billing.VmLease
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Metering
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp org!,
    do:
      Repo.insert!(Organization.changeset(%Organization{}, %{name: "Org", slug: "org-#{uniq()}"}))

  defp pipeline!(org),
    do:
      Repo.insert!(
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "P",
          slug: "p-#{uniq()}",
          repository: "o/r",
          default_branch: "main"
        })
      )

  defp build!(attrs),
    do:
      Repo.insert!(
        Build.changeset(%Build{}, Map.merge(%{external_build_id: Ecto.UUID.generate()}, attrs))
      )

  defp job!(build, attrs),
    do:
      Repo.insert!(
        Job.changeset(
          %Job{},
          Map.merge(
            %{build_id: build.id, step_key: "a-#{uniq()}", command: "x", state: "passed"},
            attrs
          )
        )
      )

  test "records a lease + debit for a job that ran a VM, attributed to its org" do
    org = org!()
    pipeline = pipeline!(org)
    build = build!(%{pipeline_id: pipeline.id})

    job =
      job!(build, %{
        started_at: ~U[2026-01-01 00:00:00Z],
        finished_at: ~U[2026-01-01 00:05:00Z]
      })

    assert {:ok, %{lease: lease}} = Metering.meter_finished_job(job, Repo)
    assert lease.organization_id == org.id
    assert lease.job_id == job.id
    assert lease.pipeline_id == pipeline.id
    assert lease.cpu_count == 2
    assert lease.memory_gb == 4
    assert lease.disk_gb == 20
    assert lease.duration_seconds == 300
  end

  test "is a no-op for a job that never ran a VM (started_at is nil)" do
    org = org!()
    build = build!(%{pipeline_id: pipeline!(org).id})
    job = job!(build, %{started_at: nil, finished_at: ~U[2026-01-01 00:00:00Z]})

    assert :noop = Metering.meter_finished_job(job, Repo)
    assert Repo.aggregate(from(l in VmLease, where: l.job_id == ^job.id), :count) == 0
  end

  test "is a no-op when the build has no pipeline (no org to attribute to)" do
    build = build!(%{pipeline_id: nil})

    job =
      job!(build, %{started_at: ~U[2026-01-01 00:00:00Z], finished_at: ~U[2026-01-01 00:01:00Z]})

    assert :noop = Metering.meter_finished_job(job, Repo)
    assert Repo.aggregate(from(l in VmLease, where: l.job_id == ^job.id), :count) == 0
  end

  test "a second call for the same job records nothing new" do
    org = org!()
    build = build!(%{pipeline_id: pipeline!(org).id})

    job =
      job!(build, %{started_at: ~U[2026-01-01 00:00:00Z], finished_at: ~U[2026-01-01 00:05:00Z]})

    assert {:ok, %{lease: _}} = Metering.meter_finished_job(job, Repo)
    assert {:ok, :already_recorded} = Metering.meter_finished_job(job, Repo)
    assert Repo.aggregate(from(l in VmLease, where: l.job_id == ^job.id), :count) == 1
  end
end
