defmodule Harmont.Accounts.MagicLink do
  @moduledoc "A single-use magic-link token that lets a known user authenticate without a password."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "magic_links" do
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)

    belongs_to(:user, Harmont.Accounts.User)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a magic link."
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:token_hash, :expires_at, :user_id])
    |> validate_required([:token_hash, :expires_at, :user_id])
    |> unique_constraint(:token_hash)
  end
end
