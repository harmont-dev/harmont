defmodule Harmont.Repo.Migrations.DropGithubTables do
  use Ecto.Migration

  @moduledoc """
  Final cutover: the GitHub-only tables are fully superseded by the vcs_* tables
  (created + backfilled in 20260607000001). Drop them. Irreversible by design —
  `down` raises; restore from backup if a rollback is genuinely required.
  """

  def up do
    drop table(:check_run_mapping)

    # Long-lived DBs (prod) still carry a FK from pipelines -> github_repo
    # (`pipelines_github_repo_id_fkey`); dropping github_repo while that
    # constraint exists raises 2BP01 (dependent_objects_still_exist). Drop the
    # constraint defensively first. `IF EXISTS` keeps this a no-op on a clean DB
    # where no migration ever created the column/FK.
    execute("ALTER TABLE pipelines DROP CONSTRAINT IF EXISTS pipelines_github_repo_id_fkey")

    drop table(:github_repo)
    drop table(:github_installation)
    drop table(:webhook_delivery)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: github_* tables were dropped after backfill into vcs_*. " <>
          "Restore from backup if a rollback is genuinely required."
  end
end
