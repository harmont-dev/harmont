defmodule Harmont.Repo.Migrations.DropProviderCheckLegacyVocabulary do
  @moduledoc """
  Drop the legacy GitHub-vocabulary `status`/`conclusion` columns from
  `vcs_provider_check`. The neutral `state` column (added + backfilled by
  `20260610000001`) is now the single source of truth, and all readers/writers
  use it (the dual-read/dual-write code was removed in the same change).

  This is safe to drop unconditionally in this release: `vcs_provider_check` is
  created on this branch (it does not exist on the currently-deployed prod
  schema), so no in-flight app instance reads `status`/`conclusion` from it. The
  earlier deferred "flip a flag next release" design was abandoned because Ecto
  records a migration by version regardless of body — a flag flip can never
  re-run an already-recorded version — so the only correct way to drop the
  columns is a real migration, here.
  """
  use Ecto.Migration

  def up do
    alter table(:vcs_provider_check) do
      remove :status
      remove :conclusion
    end
  end

  def down do
    # Re-add nullable and reconstruct the GitHub-vocabulary literals from the
    # neutral `state` so a rollback restores a consistent, readable schema.
    alter table(:vcs_provider_check) do
      add :status, :string
      add :conclusion, :string
    end

    execute("""
    UPDATE vcs_provider_check
    SET status = CASE state
                   WHEN 'queued' THEN 'queued'
                   WHEN 'running' THEN 'in_progress'
                   ELSE 'completed'
                 END,
        conclusion = CASE state
                       WHEN 'passed' THEN 'success'
                       WHEN 'failed' THEN 'failure'
                       WHEN 'canceled' THEN 'cancelled'
                       WHEN 'neutral' THEN 'neutral'
                       ELSE NULL
                     END
    """)
  end
end
