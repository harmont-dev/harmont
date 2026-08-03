defmodule Harmont.Repo.Migrations.DropPipelineCronNextFireAt do
  @moduledoc """
  Drop the dead `pipelines.cron_next_fire_at` column.

  It was the persistence point for an abandoned poll-based scheduler (a sweep
  would scan for due `cron_next_fire_at` rows). Scheduled pipelines now run on
  Oban Pro DynamicCron, which stores each schedule's next-fire state itself
  (per-entry `pipeline-<id>` cron), so this column is superseded and never read.
  """
  use Ecto.Migration

  def up do
    alter table(:pipelines) do
      remove :cron_next_fire_at
    end
  end

  def down do
    alter table(:pipelines) do
      add :cron_next_fire_at, :utc_datetime_usec
    end
  end
end
