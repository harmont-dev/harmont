defmodule Harmont.Repo.Migrations.AddTimeoutMsToBuilds do
  use Ecto.Migration

  def change do
    alter table(:builds) do
      # Whole-build wall-clock budget in milliseconds; null = no budget.
      add :timeout_ms, :integer
    end
  end
end
