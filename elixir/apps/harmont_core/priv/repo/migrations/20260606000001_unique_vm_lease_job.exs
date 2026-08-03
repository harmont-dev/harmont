defmodule Harmont.Repo.Migrations.UniqueVmLeaseJob do
  use Ecto.Migration

  def change do
    create unique_index(:vm_leases, [:job_id],
             where: "job_id IS NOT NULL",
             name: :vm_leases_job_id_index
           )
  end
end
