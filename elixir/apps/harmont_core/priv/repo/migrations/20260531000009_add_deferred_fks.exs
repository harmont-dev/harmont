defmodule Harmont.Repo.Migrations.AddDeferredFks do
  @moduledoc """
  Wires the foreign keys that were deferred because their target tables didn't
  exist at migration time.

  Three pairs of changes:

  1. `github_installation.organization_id` — was `:bigint` (bare, no FK) because
     `organizations` didn't exist in Plan 0.  `organizations` now uses
     `binary_id` PKs, so this column must change type too.  The table is
     greenfield with no prod data, so we drop and re-add the column as
     `:binary_id` and attach the FK (nullable, nilify-on-org-delete).

  2. `users.personal_org_id` — was a bare `:binary_id` column (Plan 2 Task 2).
     Now that `organizations` exists we attach the FK constraint
     (nullable, nilify-on-org-delete).

  3. `vm_leases.job_id` / `vm_leases.pipeline_id` — bare `:binary_id` columns
     (Plan 2 Task 7).  Wire FKs to `jobs(id)` and `pipelines(id)` respectively
     (both nullable, nilify-on-delete).

  Verified-already-wired FKs (no action needed here):
  - `builds.pipeline_id` → `pipelines(id)`           (T6 migration)
  - `builds.created_by_id` → `users(id)`              (T6 migration)
  - `jobs.retried_in_job_id` → `jobs(id)` (self)      (T6 migration)
  - `artifacts.job_id` → `jobs(id)`                   (T5 migration)
  - `runner_tokens.build_id` → `builds(id)`           (T5 migration)
  - All billing FKs (org, user, coupon refs)           (T7 migration)
  """
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # 1. github_installation.organization_id  bigint → binary_id + FK
    # ------------------------------------------------------------------
    # !!! GREENFIELD-ONLY / DATA-LOSSY ON REPLAY !!!
    # This DROPs the existing organization_id column and re-ADDs it as a fresh
    # binary_id. Every value in the dropped column is permanently lost. This is
    # only safe because `github_installation` is empty at the time this
    # migration runs (greenfield cutover, no prod data). DO NOT replay this
    # against a populated table — it will silently discard every
    # github_installation → organization link. If a future migration needs to
    # change this column's type on a non-empty table, write a proper
    # ALTER ... USING cast or a backfill, never a drop/re-add.
    alter table(:github_installation) do
      remove(:organization_id)
    end

    # Re-add as binary_id with the FK constraint.
    alter table(:github_installation) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end

    # ------------------------------------------------------------------
    # 2. users.personal_org_id  bare binary_id → FK to organizations
    # ------------------------------------------------------------------
    alter table(:users) do
      modify(
        :personal_org_id,
        references(:organizations, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: {:binary_id, null: true}
      )
    end

    # ------------------------------------------------------------------
    # 3. vm_leases.job_id / pipeline_id  bare binary_id → FK
    # ------------------------------------------------------------------
    alter table(:vm_leases) do
      modify(
        :job_id,
        references(:jobs, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: {:binary_id, null: true}
      )

      modify(
        :pipeline_id,
        references(:pipelines, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: {:binary_id, null: true}
      )
    end
  end
end
