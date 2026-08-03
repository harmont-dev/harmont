defmodule Harmont.Accounts.User do
  @moduledoc "A Harmont user account. Email is always stored in lowercased, trimmed form."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:name, :string)
    field(:email, :string)
    field(:google_id, :string)
    field(:github_id, :string)
    # Bare column for now; FK to organizations added in Task 8.
    field(:personal_org_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating or updating a user."
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :google_id, :github_id, :personal_org_id])
    |> validate_required([:name, :email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end

  @doc "Changeset for a user-editable profile update (name only)."
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end
