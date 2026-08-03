defmodule Harmont.Repo.Migrations.IndexVmLeasesOrgStarted do
  use Ecto.Migration

  def change do
    create index(:vm_leases, [:organization_id, :started_at])
  end
end
