defmodule Harmont.Repo.Migrations.CreateOrgInvites do
  use Ecto.Migration

  def change do
    create table(:org_invites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:invited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(:email, :string, null: false)
      add(:role, :string, null: false)
      add(:token_hash, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:accepted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:org_invites, [:token_hash]))
    create(index(:org_invites, [:organization_id]))

    create(
      unique_index(:org_invites, [:organization_id, :email],
        where: "accepted_at IS NULL",
        name: :org_invites_pending_unique
      )
    )
  end
end
