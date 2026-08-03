defmodule Harmont.Orgs.Invite do
  @moduledoc "A pending invitation for an email to join an organization with a role."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_invites" do
    belongs_to(:organization, Harmont.Orgs.Organization)
    belongs_to(:invited_by, Harmont.Accounts.User, foreign_key: :invited_by_user_id)

    field(:email, :string)
    field(:role, Ecto.Enum, values: [:admin, :member])
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an invite. Email is lowercased/trimmed."
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :organization_id,
      :invited_by_user_id,
      :email,
      :role,
      :token_hash,
      :expires_at,
      :accepted_at
    ])
    |> validate_required([:organization_id, :email, :role, :token_hash, :expires_at])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/@/)
    |> unique_constraint([:organization_id, :email], name: :org_invites_pending_unique)
    |> unique_constraint(:token_hash)
  end
end
