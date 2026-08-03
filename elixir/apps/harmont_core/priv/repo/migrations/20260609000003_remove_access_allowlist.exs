defmodule Harmont.Repo.Migrations.RemoveAccessAllowlist do
  use Ecto.Migration

  def up do
    # Drop the invite-only allowlist; signups are now open and capped instead.
    drop(table(:access_allowlist_entries))

    # The signup_attempts.decision enum is narrowing to
    # [:allowed, :denied_cap_reached]; historical denial/request rows carry
    # values the new enum can't load, so purge them. (Audit of who signed up —
    # the :allowed rows — is preserved.)
    execute("DELETE FROM signup_attempts WHERE decision NOT IN ('allowed', 'denied_cap_reached')")
  end

  def down do
    # Recreate the allowlist table as it was (the purged signup_attempts rows
    # are not recoverable).
    create table(:access_allowlist_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :string, null: false)
      add(:value, :string, null: false)
      add(:added_by, :string, null: false)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:access_allowlist_entries, [:kind, :value]))
  end
end
