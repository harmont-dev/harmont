defmodule Harmont.Repo.Migrations.VcsInstallationOrgFkDropPlaintextCreds do
  @moduledoc """
  Two fixes to `vcs_installation`:

  1. Restore the lost `organization_id` FK. The table was created with a bare
     `:uuid` column (see CreateVcsTables), dropping the
     `references(:organizations, on_delete: :nilify_all)` the old
     `github_installation.organization_id` carried. Without it, deleting an org
     leaves dangling org ids (`resolve_org` -> nil -> 0 builds) and bad ids
     insert silently instead of raising `23503`.

  2. Drop the plaintext `:credentials` jsonb column. Credentials now live in the
     Cloak-encrypted `:credentials_encrypted`; the plaintext column is a footgun
     that invites writing OAuth tokens in the clear.
  """
  use Ecto.Migration

  def up do
    # NULL out any rows pointing at an organization that no longer exists, so the
    # FK can be added without violating it.
    execute("""
    UPDATE vcs_installation
    SET organization_id = NULL
    WHERE organization_id IS NOT NULL
      AND organization_id NOT IN (SELECT id FROM organizations)
    """)

    alter table(:vcs_installation) do
      modify :organization_id,
             references(:organizations, type: :binary_id, on_delete: :nilify_all),
             from: :uuid

      remove :credentials
    end
  end

  def down do
    alter table(:vcs_installation) do
      add :credentials, :map, null: true

      modify :organization_id, :uuid,
        from: references(:organizations, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
