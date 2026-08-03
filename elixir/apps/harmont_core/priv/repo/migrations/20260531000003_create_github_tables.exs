defmodule Harmont.Repo.Migrations.CreateGithubTables do
  use Ecto.Migration

  def change do
    create table(:github_installation, primary_key: false) do
      add :id, :bigserial, primary_key: true
      # FK to organization deferred to Plan 2 (organization table doesn't exist yet).
      # Nullable — set by harmont-api during OAuth/sync; this app creates rows
      # without it on installation.created webhooks.
      add :organization_id, :bigint, null: true
      add :installation_id, :bigint, null: false
      add :account_login, :string, null: false
      add :account_type, :string, null: false
      # Tombstone columns: set on installation.suspend / installation.deleted webhooks.
      add :suspended_at, :utc_datetime_usec, null: true
      add :deleted_at, :utc_datetime_usec, null: true
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:github_installation, [:installation_id],
             name: :unique_github_installation_id)

    create table(:github_repo, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :installation_id,
          references(:github_installation,
            column: :id,
            type: :bigint,
            on_delete: :delete_all,
            on_update: :restrict
          ),
          null: false

      add :gh_repo_id, :bigint, null: false
      add :full_name, :string, null: false
      add :name, :string, null: false
      add :owner, :string, null: false
      add :clone_url, :string, null: false
      add :default_branch, :string, null: false
      add :private, :boolean, null: false
      add :last_synced_at, :utc_datetime_usec, null: false
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:github_repo, [:installation_id, :gh_repo_id],
             name: :unique_github_repo_installation_gh_id)

    create table(:check_run_mapping, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :build_uuid, :string, null: false
      add :org_slug, :string, null: false
      add :pipeline_slug, :string, null: false
      add :build_number, :bigint, null: false
      add :installation_id, :bigint, null: false
      add :owner, :string, null: false
      add :repo, :string, null: false
      add :head_sha, :string, null: false
      # head_branch: records the originating git branch; nullable for backwards
      # compatibility with rows created before this column existed.
      add :head_branch, :string, null: true
      add :check_run_id, :bigint, null: false
      add :status, :string, null: false
      add :conclusion, :string, null: true
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:check_run_mapping, [:build_uuid],
             name: :unique_check_run_mapping_build)

    # Partial index over open (non-completed) check runs — mirrors the Atlas baseline.
    create index(:check_run_mapping, [:status],
             name: :idx_check_run_mapping_status_open,
             where: "(status)::text <> 'completed'::text"
           )

    create table(:webhook_delivery, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :delivery_id, :string, null: false
      add :event, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create unique_index(:webhook_delivery, [:delivery_id], name: :unique_webhook_delivery_id)
  end
end
