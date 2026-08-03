defmodule Harmont.Accounts.WebauthnCredential do
  @moduledoc "A registered WebAuthn/passkey credential belonging to a user."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webauthn_credentials" do
    field(:credential_id, :binary)
    field(:user_handle, :binary)
    field(:public_key, :binary)
    field(:sign_count, :integer)
    field(:transports, :string)
    field(:aaguid, :string)
    field(:nickname, :string)
    field(:locked, :boolean, default: false)
    field(:last_used_at, :utc_datetime_usec)

    belongs_to(:user, Harmont.Accounts.User)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for registering a new WebAuthn credential."
  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [
      :credential_id,
      :user_handle,
      :public_key,
      :sign_count,
      :transports,
      :aaguid,
      :nickname,
      :locked,
      :last_used_at,
      :user_id
    ])
    |> validate_required([:credential_id, :user_handle, :public_key, :sign_count, :user_id])
    |> unique_constraint(:credential_id)
  end
end
