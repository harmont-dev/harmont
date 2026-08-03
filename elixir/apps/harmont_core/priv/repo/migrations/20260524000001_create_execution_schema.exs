defmodule Harmont.Repo.Migrations.CreateExecutionSchema do
  use Ecto.Migration

  def change do
    create table(:builds) do
      add :external_build_id, :uuid, null: false
      add :state, :string, null: false, default: "scheduled"
      add :cancel_requested, :boolean, null: false, default: false
      add :source_url, :string
      add :runner_token_hash, :binary
      add :default_image, :string
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:builds, [:external_build_id])

    create table(:jobs) do
      add :build_id, references(:builds, type: :binary_id, on_delete: :delete_all), null: false
      add :step_key, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :command, :text, null: false
      add :image, :string
      add :env, :map, null: false, default: %{}
      add :timeout_ms, :integer
      add :builds_in, :string
      add :runner, :string
      add :runner_args, :map
      add :cache_key, :string
      add :snapshot_id, :string
      add :exit_code, :integer
      add :error_code, :string
      add :error_message, :text
      add :last_heartbeat_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:jobs, [:build_id, :step_key])
    create index(:jobs, [:state])
    create index(:jobs, [:last_heartbeat_at])

    create table(:job_deps) do
      add :dependent_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false

      add :prerequisite_id, references(:jobs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:job_deps, [:dependent_id, :prerequisite_id])

    create table(:log_chunks) do
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :stream_kind, :integer, null: false, default: 0
      add :content, :binary, null: false
      add :ts_unix_ns, :bigint
      add :instance_id, :string
      timestamps(updated_at: false)
    end

    create unique_index(:log_chunks, [:job_id, :seq])
  end
end
