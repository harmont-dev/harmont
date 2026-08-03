defmodule Harmont.Repo.Migrations.CreateSandboxes do
  @moduledoc """
  The `sandboxes` registry: the authoritative record of every VM sandbox the
  platform provisions through `backend.provision/1` (job, fork-parent, render).
  Recorded at provision time regardless of any provider-side relabel, so a
  sandbox can never become invisible to the reaper. Templates are NOT tracked
  here — they are created inside `harmont_vm` (no Repo) and managed by label.

  `external_id` is the provider's own sandbox id (Daytona sandbox id, etc.),
  unique per `provider`. `state` is `active` (in use) or `deleted` (we have
  destroyed it or reconciled it away). `kind` is `job` | `fork_parent` |
  `render`. `job_id` / `build_id` are nullable (render sandboxes have neither).
  """
  use Ecto.Migration

  def change do
    create table(:sandboxes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :external_id, :string, null: false
      add :kind, :string, null: false
      add :state, :string, null: false, default: "active"
      add :job_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
      add :build_id, references(:builds, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sandboxes, [:provider, :external_id])
    create index(:sandboxes, [:provider, :state])
    create index(:sandboxes, [:build_id])
  end
end
