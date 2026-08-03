defmodule Harmont.Repo.Migrations.CreateOrgs do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:slug])

    create table(:org_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:org_members, [:organization_id, :user_id])

    create table(:access_allowlist_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :value, :string, null: false
      add :added_by, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:access_allowlist_entries, [:kind, :value])

    create table(:signup_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :provider, :string
      add :decision, :string, null: false
      add :request_id, :string

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end
end
