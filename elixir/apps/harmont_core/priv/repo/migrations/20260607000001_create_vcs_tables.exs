defmodule Harmont.Repo.Migrations.CreateVcsTables do
  use Ecto.Migration

  def up do
    create table(:vcs_installation, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :provider, :string, null: false
      add :external_id, :string, null: false
      # Match the live github_installation.organization_id type (uuid per the
      # Harmont.Github.Installation schema). Confirmed uuid (binary_id).
      add :organization_id, :uuid, null: true
      add :account_login, :string, null: false
      add :account_type, :string, null: false
      add :credentials, :map, null: true
      add :suspended_at, :utc_datetime_usec, null: true
      add :deleted_at, :utc_datetime_usec, null: true
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:vcs_installation, [:provider, :external_id],
             name: :unique_vcs_installation_provider_external)

    create table(:vcs_repo, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :installation_id,
          references(:vcs_installation,
            column: :id,
            type: :bigint,
            on_delete: :delete_all,
            on_update: :restrict
          ),
          null: false

      add :provider, :string, null: false
      add :external_repo_id, :string, null: false
      add :full_name, :string, null: false
      add :name, :string, null: false
      add :owner, :string, null: false
      add :clone_url, :string, null: false
      add :default_branch, :string, null: false
      add :private, :boolean, null: false
      add :last_synced_at, :utc_datetime_usec, null: false
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:vcs_repo, [:installation_id, :external_repo_id],
             name: :unique_vcs_repo_installation_external)

    create table(:vcs_provider_check, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :build_uuid, :string, null: false
      add :provider, :string, null: false
      add :org_slug, :string, null: false
      add :pipeline_slug, :string, null: false
      add :build_number, :bigint, null: false
      add :installation_external_id, :string, null: false
      add :owner, :string, null: false
      add :repo, :string, null: false
      add :head_sha, :string, null: false
      add :head_branch, :string, null: true
      add :provider_check_id, :string, null: false
      add :status, :string, null: false
      add :conclusion, :string, null: true
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:vcs_provider_check, [:build_uuid],
             name: :unique_vcs_provider_check_build)

    create index(:vcs_provider_check, [:status],
             where: "status <> 'completed'",
             name: :vcs_provider_check_open_idx)

    create table(:vcs_webhook_delivery, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :provider, :string, null: false
      add :delivery_id, :string, null: false
      add :event, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create unique_index(:vcs_webhook_delivery, [:provider, :delivery_id],
             name: :unique_vcs_webhook_delivery)

    # ---- Backfill from the GitHub-only tables (idempotent: ON CONFLICT DO NOTHING) ----
    execute("""
    INSERT INTO vcs_installation
      (provider, external_id, organization_id, account_login, account_type,
       suspended_at, deleted_at, created_at, updated_at)
    SELECT 'github', installation_id::text, organization_id, account_login,
           account_type, suspended_at, deleted_at, created_at, updated_at
    FROM github_installation
    ON CONFLICT (provider, external_id) DO NOTHING
    """)

    execute("""
    INSERT INTO vcs_repo
      (installation_id, provider, external_repo_id, full_name, name, owner,
       clone_url, default_branch, private, last_synced_at, created_at, updated_at)
    SELECT vi.id, 'github', gr.gh_repo_id::text, gr.full_name, gr.name, gr.owner,
           gr.clone_url, gr.default_branch, gr.private, gr.last_synced_at,
           gr.created_at, gr.updated_at
    FROM github_repo gr
    JOIN github_installation gi ON gi.id = gr.installation_id
    JOIN vcs_installation vi
      ON vi.provider = 'github' AND vi.external_id = gi.installation_id::text
    ON CONFLICT (installation_id, external_repo_id) DO NOTHING
    """)

    execute("""
    INSERT INTO vcs_provider_check
      (build_uuid, provider, org_slug, pipeline_slug, build_number,
       installation_external_id, owner, repo, head_sha, head_branch,
       provider_check_id, status, conclusion, created_at, updated_at)
    SELECT build_uuid, 'github', org_slug, pipeline_slug, build_number,
           installation_id::text, owner, repo, head_sha, head_branch,
           check_run_id::text, status, conclusion, created_at, updated_at
    FROM check_run_mapping
    ON CONFLICT (build_uuid) DO NOTHING
    """)

    execute("""
    INSERT INTO vcs_webhook_delivery (provider, delivery_id, event, received_at)
    SELECT 'github', delivery_id, event, received_at
    FROM webhook_delivery
    ON CONFLICT (provider, delivery_id) DO NOTHING
    """)
  end

  def down do
    drop table(:vcs_webhook_delivery)
    drop table(:vcs_provider_check)
    drop table(:vcs_repo)
    drop table(:vcs_installation)
  end
end
