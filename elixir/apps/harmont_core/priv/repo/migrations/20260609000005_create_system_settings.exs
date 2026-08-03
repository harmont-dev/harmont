defmodule Harmont.Repo.Migrations.CreateSystemSettings do
  @moduledoc """
  Creates `system_settings`. This file was RE-VERSIONED to `...000005` to
  deconflict a duplicate `20260609000002` on `origin/main` (where both this table
  and `add_stripe_customer_id_to_organizations` shared `...000002`, which makes
  `mix ecto.migrate` raise `version is duplicated`).

  Because re-versioning changes the recorded `schema_migrations` version, a DB
  that already ran the OLD `...000002` create_system_settings would see `...000005`
  as un-run and re-execute `CREATE TABLE system_settings`, failing 42P07. So this
  body is IDEMPOTENT (`create_if_not_exists`): on a DB that already has the table
  (recorded under 002) the re-run is a harmless no-op; on a fresh DB it creates
  the table normally.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:system_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:value, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(unique_index(:system_settings, [:key]))
  end
end
