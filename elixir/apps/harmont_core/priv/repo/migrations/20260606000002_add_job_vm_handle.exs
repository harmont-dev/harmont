defmodule Harmont.Repo.Migrations.AddJobVmHandle do
  @moduledoc """
  `jobs.vm_handle` records the backend's stable VM identifier (Runloop devbox id,
  Daytona sandbox id, Freestyle vm id, Local dir name) captured at provision time.
  Nullable: jobs that never provisioned a VM (or ran before this column existed)
  have no handle. Surfaced in the usage breakdown so a charge can be traced to the
  exact VM that produced it.
  """
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :vm_handle, :string, null: true
    end
  end
end
