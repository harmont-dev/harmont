defmodule Harmont.Accounts.ApiToken do
  @moduledoc "A bearer API token (session or personal access token) owned by a user."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    field(:description, :string)
    field(:token_hash, :string)
    field(:token_type, Ecto.Enum, values: [:personal, :session])
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    belongs_to(:user, Harmont.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an API token."
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:description, :token_hash, :token_type, :expires_at, :last_used_at, :user_id])
    |> validate_required([:token_hash, :token_type, :user_id])
    |> unique_constraint(:token_hash)
  end
end
