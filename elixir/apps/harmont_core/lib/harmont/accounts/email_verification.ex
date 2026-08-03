defmodule Harmont.Accounts.EmailVerification do
  @moduledoc "An email verification token sent to a user to confirm their address before account creation."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_verifications" do
    field(:token_hash, :string)
    field(:email, :string)
    field(:name, :string)
    field(:purpose, Ecto.Enum, values: [:signup])
    field(:expires_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an email verification record."
  def changeset(ev, attrs) do
    ev
    |> cast(attrs, [:token_hash, :email, :name, :purpose, :expires_at])
    |> validate_required([:token_hash, :email, :name, :purpose, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
