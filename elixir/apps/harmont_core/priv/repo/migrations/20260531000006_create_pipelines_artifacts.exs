defmodule Harmont.Repo.Migrations.CreatePipelinesArtifacts do
  use Ecto.Migration

  def change do
    create table(:pipelines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :repository, :string, null: false
      add :default_branch, :string, null: false
      add :visibility, :string, null: false, default: "private"
      add :steps_yaml, :string
      add :archived, :boolean, null: false, default: false
      add :build_count, :integer, null: false, default: 0
      add :triggers, {:array, :map}, null: false, default: []
      add :allow_manual, :boolean, null: false, default: true
      add :cron_next_fire_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pipelines, [:organization_id, :slug])

    create table(:runner_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :build_id,
          references(:builds, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:runner_tokens, [:build_id])
    create unique_index(:runner_tokens, [:token_hash])

    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :job_id,
          references(:jobs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :path, :string, null: false
      add :filename, :string, null: false
      add :mime_type, :string, null: false
      add :file_size, :integer, null: false
      add :sha1_sum, :string
      add :state, :string, null: false, default: "new"
      add :download_url, :string
      add :upload_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifacts, [:job_id])
  end
end
