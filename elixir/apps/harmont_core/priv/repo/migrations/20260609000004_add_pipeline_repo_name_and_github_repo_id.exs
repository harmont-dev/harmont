defmodule Harmont.Repo.Migrations.AddPipelineRepoNameAndGithubRepoId do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      # Denormalized "owner/repo" display string. Always populated for
      # discovered pipelines (from github_repo.full_name) and for manual /
      # API pipelines (parsed from the clone URL). Nullable for legacy rows.
      add(:repo_name, :string)

      # Denormalized GitHub numeric repo id (set from the discovered repo's id).
      # This was originally an FK to the `github_repo` table, but the VCS
      # decoupling drops that table earlier in the chain
      # (20260607000002_drop_github_tables) in favor of the vcs_* tables. The
      # Pipeline schema already models this as a plain integer
      # (`field(:github_repo_id, :integer)`, no association), so it is a bare
      # column here — no FK to a table that no longer exists.
      add(:github_repo_id, :bigint)
    end

    create(index(:pipelines, [:github_repo_id]))
  end
end
