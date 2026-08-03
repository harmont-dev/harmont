defmodule Harmont.Engine.TransitionMeteringTest do
  use Harmont.DataCase, async: true
  import Ecto.Query
  alias Harmont.Billing.{LedgerEntry, VmLease}
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Transition
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo

  defp uniq, do: System.unique_integer([:positive])

  setup do
    org =
      Repo.insert!(Organization.changeset(%Organization{}, %{name: "Org", slug: "org-#{uniq()}"}))

    pipeline =
      Repo.insert!(
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "P",
          slug: "p-#{uniq()}",
          repository: "o/r",
          default_branch: "main"
        })
      )

    build =
      Repo.insert!(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          pipeline_id: pipeline.id
        })
      )

    job =
      Repo.insert!(
        Job.changeset(%Job{}, %{build_id: build.id, step_key: "a", command: "x", state: "pending"})
      )

    %{org: org, job: job}
  end

  defp drive(job, events),
    do: Enum.each(events, fn e -> {:ok, _} = Transition.apply(job.id, e) end)

  test "a job that runs to a terminal state records exactly one lease + debit", %{
    org: org,
    job: job
  } do
    drive(job, [:ready_to_schedule, :assigned_to_sandbox, :started, :reported_passed])

    leases = Repo.all(from(l in VmLease, where: l.job_id == ^job.id))
    assert length(leases) == 1
    lease = hd(leases)
    assert lease.organization_id == org.id
    assert lease.cpu_count == 2 and lease.memory_gb == 4 and lease.disk_gb == 20
    assert lease.duration_seconds >= 0

    assert Repo.aggregate(from(e in LedgerEntry, where: e.vm_lease_id == ^lease.id), :count) == 1
  end

  test "a cache-hit pass (never ran a VM) records no lease", %{job: job} do
    # scheduled -> passed via :cache_hit; no :started, so no started_at.
    drive(job, [:ready_to_schedule, :cache_hit])
    assert Repo.aggregate(from(l in VmLease, where: l.job_id == ^job.id), :count) == 0
  end

  test "re-driving the terminal event does not double-bill", %{job: job} do
    drive(job, [:ready_to_schedule, :assigned_to_sandbox, :started, :reported_passed])

    # Re-applying a terminal event is an illegal arc -> {:noop, _}; assert no extra lease either way.
    assert {:noop, _} = Transition.apply(job.id, :reported_passed)
    assert Repo.aggregate(from(l in VmLease, where: l.job_id == ^job.id), :count) == 1
  end
end
