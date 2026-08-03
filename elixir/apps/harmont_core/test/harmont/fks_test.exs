defmodule Harmont.FksTest do
  @moduledoc """
  Referential-integrity smoke tests for the FKs wired in Task 8.

  Tests cover:
  - `users.personal_org_id` → `organizations(id)` (nilify on org delete)
  - `vm_leases.job_id` → `jobs(id)` (nilify on job delete)
  - `vm_leases.pipeline_id` → `pipelines(id)` (nilify on pipeline delete)
  - `vcs_installation.organization_id` → `organizations(id)` (FK + nilify on org
    delete) — re-adds the coverage lost with the old GitHub `fks_test`.
  """

  use Harmont.DataCase

  alias Harmont.Accounts.User
  alias Harmont.Artifacts.Artifact
  alias Harmont.Billing.VmLease
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Pipelines.RunnerTokens
  alias Harmont.Repo
  alias Harmont.Vcs.Installation

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_org!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Test Org #{System.unique_integer([:positive])}",
          slug: "test-#{System.unique_integer([:positive])}"
        },
        attrs
      )

    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, attrs))
    org
  end

  defp insert_user!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{name: "User #{n}", email: "user#{n}@example.com"},
        attrs
      )

    {:ok, user} = Repo.insert(User.changeset(%User{}, attrs))
    user
  end

  defp insert_build! do
    {:ok, build} =
      Repo.insert(%Build{
        external_build_id: Ecto.UUID.generate(),
        state: "scheduled",
        default_image: "ubuntu:22.04"
      })

    build
  end

  defp insert_job!(build_id) do
    {:ok, job} =
      Repo.insert(%Job{
        build_id: build_id,
        step_key: "step-#{System.unique_integer([:positive])}",
        command: "echo hi",
        state: "scheduled"
      })

    job
  end

  defp insert_pipeline!(org_id) do
    {:ok, pipeline} =
      Repo.insert(
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org_id,
          name: "Test Pipeline #{System.unique_integer([:positive])}",
          slug: "pipe-#{System.unique_integer([:positive])}",
          repository: "https://github.com/example/repo",
          default_branch: "main"
        })
      )

    pipeline
  end

  defp insert_vm_lease!(org_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          organization_id: org_id,
          cpu_count: 2,
          memory_gb: 4,
          disk_gb: 20,
          started_at: DateTime.utc_now()
        },
        attrs
      )

    {:ok, lease} = Repo.insert(VmLease.changeset(%VmLease{}, attrs))
    lease
  end

  defp insert_installation!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, inst} =
      %{
        provider: "github",
        external_id: "ext-#{n}",
        account_name: "acct-#{n}",
        account_kind: "Organization"
      }
      |> Installation.upsert_changeset()
      |> Ecto.Changeset.put_change(:organization_id, org_id)
      |> Repo.insert()

    inst
  end

  # ---------------------------------------------------------------------------
  # users.personal_org_id FK + nilify on org delete
  # ---------------------------------------------------------------------------

  describe "users.personal_org_id FK" do
    test "personal_org_id is nilified when the referenced organization is deleted" do
      org = insert_org!()
      user = insert_user!(%{personal_org_id: org.id})

      assert user.personal_org_id == org.id

      # Deleting the org should nilify the user's personal_org_id.
      Repo.delete!(org)

      refreshed = Repo.get!(User, user.id)
      assert is_nil(refreshed.personal_org_id)
    end

    test "personal_org_id can be nil (no org yet)" do
      user = insert_user!()
      assert is_nil(user.personal_org_id)
    end
  end

  # ---------------------------------------------------------------------------
  # vm_leases.job_id FK + nilify on job delete
  # ---------------------------------------------------------------------------

  describe "vm_leases.job_id FK" do
    test "job_id is nilified when the referenced job is deleted" do
      org = insert_org!()
      build = insert_build!()
      job = insert_job!(build.id)
      lease = insert_vm_lease!(org.id, %{job_id: job.id})

      assert lease.job_id == job.id

      Repo.delete!(job)

      refreshed = Repo.get!(VmLease, lease.id)
      assert is_nil(refreshed.job_id)
    end

    test "job_id can be nil" do
      org = insert_org!()
      lease = insert_vm_lease!(org.id)
      assert is_nil(lease.job_id)
    end
  end

  # ---------------------------------------------------------------------------
  # vm_leases.pipeline_id FK + nilify on pipeline delete
  # ---------------------------------------------------------------------------

  describe "vm_leases.pipeline_id FK" do
    test "pipeline_id is nilified when the referenced pipeline is deleted" do
      org = insert_org!()
      pipeline = insert_pipeline!(org.id)
      lease = insert_vm_lease!(org.id, %{pipeline_id: pipeline.id})

      assert lease.pipeline_id == pipeline.id

      Repo.delete!(pipeline)

      refreshed = Repo.get!(VmLease, lease.id)
      assert is_nil(refreshed.pipeline_id)
    end

    test "pipeline_id can be nil" do
      org = insert_org!()
      lease = insert_vm_lease!(org.id)
      assert is_nil(lease.pipeline_id)
    end
  end

  # ---------------------------------------------------------------------------
  # vcs_installation.organization_id FK + nilify on org delete
  # ---------------------------------------------------------------------------

  describe "vcs_installation.organization_id FK" do
    test "organization_id is nilified when the referenced organization is deleted" do
      org = insert_org!()
      inst = insert_installation!(org.id)

      assert inst.organization_id == org.id

      Repo.delete!(org)

      refreshed = Repo.get!(Installation, inst.id)
      assert is_nil(refreshed.organization_id)
    end

    test "inserting with a non-existent organization_id raises a foreign_key_violation" do
      bogus = Ecto.UUID.generate()

      # The insert goes through a changeset, so Ecto intercepts the raw 23503
      # foreign_key_violation and — finding no matching `foreign_key_constraint`
      # declared on the changeset — re-raises it as an Ecto.ConstraintError that
      # still carries the underlying constraint name. This is the FK doing its
      # job at the DB level; it just surfaces through Ecto's translation layer.
      assert_raise Ecto.ConstraintError, ~r/vcs_installation_organization_id_fkey/, fn ->
        %{
          provider: "github",
          external_id: "ext-#{System.unique_integer([:positive])}",
          account_name: "acct",
          account_kind: "Organization"
        }
        |> Installation.upsert_changeset()
        |> Ecto.Changeset.put_change(:organization_id, bogus)
        |> Repo.insert!()
      end
    end

    test "organization_id can be nil (unattached installation)" do
      {:ok, inst} =
        %{
          provider: "github",
          external_id: "ext-#{System.unique_integer([:positive])}",
          account_name: "acct",
          account_kind: "Organization"
        }
        |> Installation.upsert_changeset()
        |> Repo.insert()

      assert is_nil(inst.organization_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Confirmed existing FKs (sanity assertions via successful inserts)
  # ---------------------------------------------------------------------------

  describe "confirmed existing FKs" do
    test "builds.pipeline_id FK exists (pipeline present → no constraint error)" do
      org = insert_org!()
      pipeline = insert_pipeline!(org.id)

      {:ok, build} =
        Repo.insert(%Build{
          external_build_id: Ecto.UUID.generate(),
          state: "scheduled",
          default_image: "ubuntu:22.04",
          pipeline_id: pipeline.id
        })

      assert build.pipeline_id == pipeline.id
    end

    test "artifacts.job_id FK exists (job present → no constraint error)" do
      build = insert_build!()
      job = insert_job!(build.id)

      {:ok, artifact} =
        Repo.insert(
          Artifact.changeset(%Artifact{}, %{
            job_id: job.id,
            path: "/out/",
            filename: "result.bin",
            mime_type: "application/octet-stream",
            file_size: 1024,
            state: :new
          })
        )

      assert artifact.job_id == job.id
    end

    test "runner_tokens.build_id FK exists" do
      build = insert_build!()

      {:ok, {_raw, token}} = RunnerTokens.issue(build.id, DateTime.utc_now(), Repo)
      assert token.build_id == build.id
    end
  end
end
