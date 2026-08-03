defmodule Harmont.Repo.Migrations.UnifyBuildsJobs do
  @moduledoc """
  Extend `builds` and `jobs` with the rich API domain fields so a single schema
  serves both the executor (execution state) and the API (pipeline linkage,
  source provenance, retry/soft-fail policies).

  All new columns are nullable or have defaults so existing executor inserts
  that omit the new fields continue to succeed without modification.

  Reconciliation decisions:
  - `builds.external_build_id` is kept as-is; the executor and agent key on it.
    Collapsing it to the uuid PK is deferred to a later plan when the API creates
    builds directly.
  - `jobs.exit_code` is the canonical name (executor + agent + proto use it).
    The API's `exit_status` concept maps to this column; no duplicate is added.
  - `jobs.error_code` / `jobs.error_message` already exist on jobs — not added.
  - Build and job `state` enum vocabulary is unchanged; the executor's string
    values are preserved verbatim.
  """
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # builds — add domain / provenance columns
    # ------------------------------------------------------------------
    alter table(:builds) do
      # Pipeline linkage (nullable — raw executor builds may not have a pipeline)
      add(:pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      # Per-pipeline sequential build number (nullable for executor-only builds)
      add(:number, :integer, null: true)

      # Build source (nullable for executor-only builds)
      add(:source, :string, null: true)

      # Commit provenance (all nullable)
      add(:branch, :string, null: true)
      add(:commit, :string, null: true)
      add(:message, :text, null: true)
      add(:author, :string, null: true)

      # Who triggered the build (nullable)
      add(
        :created_by_id,
        references(:users, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      # Error info at the build level (jobs already have their own error columns)
      add(:error_code, :string, null: true)
      add(:error_message, :text, null: true)

      # When the build was scheduled (for queue-time latency; nullable)
      add(:scheduled_at, :utc_datetime_usec, null: true)
    end

    # Unique per-pipeline build number; partial index so NULL pipeline_id rows
    # don't conflict with each other.
    create(
      unique_index(:builds, [:pipeline_id, :number],
        where: "pipeline_id IS NOT NULL",
        name: :builds_pipeline_id_number_index
      )
    )

    create(index(:builds, [:pipeline_id]))

    # ------------------------------------------------------------------
    # jobs — add retry, soft-fail, and policy columns
    # ------------------------------------------------------------------
    alter table(:jobs) do
      # Human-readable job name (nullable; executor uses step_key as the key)
      add(:name, :string, null: true)

      # Job type (nullable; default is :script for executor-created jobs)
      add(:job_type, :string, null: true)

      # Soft-fail flag: job "failed" but the build is allowed to continue
      add(:soft_failed, :boolean, null: false, default: false)

      # Retry tracking
      add(:retried, :boolean, null: false, default: false)
      add(:retries_count, :integer, null: false, default: 0)

      # If this job was retried, the new job's id goes here (self-FK)
      add(
        :retried_in_job_id,
        references(:jobs, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      # JSONB policy blobs (nullable; only set by API-created jobs)
      add(:soft_fail_policy, :map, null: true)
      add(:retry_policy, :map, null: true)
      add(:cache_result, :map, null: true)
    end
  end
end
