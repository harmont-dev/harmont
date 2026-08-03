defmodule Harmont.Accounts.WebauthnChallenge do
  @moduledoc "An ephemeral WebAuthn challenge. The row's UUID is the challenge_id returned to the client; the raw challenge bytes are stored in `challenge`."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webauthn_challenges" do
    field(:challenge, :binary)
    field(:purpose, Ecto.Enum, values: [:signup, :login, :register, :recover_register])
    # Nullable: not set during initial signup flow before user exists.
    field(:user_id, :binary_id)
    field(:user_handle, :binary)
    field(:pending_signup_token_hash, :string)
    field(:pending_magic_link_token_hash, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a WebAuthn challenge."
  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [
      :challenge,
      :purpose,
      :user_id,
      :user_handle,
      :pending_signup_token_hash,
      :pending_magic_link_token_hash,
      :expires_at
    ])
    |> validate_required([:challenge, :purpose, :expires_at])
  end
end
