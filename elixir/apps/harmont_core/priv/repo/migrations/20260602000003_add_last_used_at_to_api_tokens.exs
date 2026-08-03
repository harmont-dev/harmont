defmodule Harmont.Repo.Migrations.AddLastUsedAtToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :last_used_at, :utc_datetime_usec
    end
  end
end
