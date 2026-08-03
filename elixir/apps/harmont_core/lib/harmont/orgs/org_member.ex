defmodule Harmont.Orgs.OrgMember do
  @moduledoc "Membership record linking a user to an organization with a role."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_members" do
    belongs_to(:organization, Harmont.Orgs.Organization)
    belongs_to(:user, Harmont.Accounts.User)
    field(:role, Ecto.Enum, values: [:owner, :admin, :member])

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an org membership."
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:organization_id, :user_id, :role])
    |> validate_required([:organization_id, :user_id, :role])
    |> unique_constraint([:organization_id, :user_id])
  end
end
