defmodule Harmont.Orgs.SignupAttempt do
  @moduledoc """
  Records the outcome of a sign-up attempt: `:allowed` for a successful
  sign-up, or `:denied_cap_reached` when the platform signup cap turned the
  user away.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "signup_attempts" do
    field(:email, :string)
    field(:provider, Ecto.Enum, values: [:passkey, :google, :github])

    field(:decision, Ecto.Enum, values: [:allowed, :denied_cap_reached])

    field(:request_id, :string)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for recording a sign-up attempt."
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:email, :provider, :decision, :request_id])
    |> validate_required([:email, :decision])
  end
end
