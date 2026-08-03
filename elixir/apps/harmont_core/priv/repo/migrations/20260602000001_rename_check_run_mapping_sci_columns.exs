defmodule Harmont.Repo.Migrations.RenameCheckRunMappingSciColumns do
  @moduledoc """
  The `refactor/misnomers` change dropped the `sci_` prefix from the
  `check_run_mapping` columns in the schema AND edited the original
  `create_github_tables` migration in place. Editing an already-applied
  migration is a no-op for databases that ran the old version, so prod kept the
  old column names while the schema began querying the new ones — every boot
  crashed `Harmont.GhApp.Reporter` with `column build_uuid does not exist`.

  This migration renames the four columns for real. Each rename is guarded so it
  is a no-op on a fresh database (where `create_github_tables` already produced
  the new names) and only fires where the old `sci_`-prefixed column still
  exists — making it safe to apply everywhere exactly once.
  """
  use Ecto.Migration

  @renames [
    {"sci_build_uuid", "build_uuid"},
    {"sci_org_slug", "org_slug"},
    {"sci_pipeline_slug", "pipeline_slug"},
    {"sci_build_number", "build_number"}
  ]

  def up, do: Enum.each(@renames, fn {old, new} -> rename_if_present(old, new) end)
  def down, do: Enum.each(@renames, fn {old, new} -> rename_if_present(new, old) end)

  # Rename `from` → `to` only when `from` exists and `to` does not, so the
  # migration converges whether the table still has the legacy names (prod) or
  # already has the new ones (a freshly-created DB).
  defp rename_if_present(from, to) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'check_run_mapping' AND column_name = '#{from}'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'check_run_mapping' AND column_name = '#{to}'
      ) THEN
        ALTER TABLE check_run_mapping RENAME COLUMN #{from} TO #{to};
      END IF;
    END $$;
    """)
  end
end
