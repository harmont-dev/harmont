defmodule Harmont.Billing.StripeCheckoutSession do
  @moduledoc """
  Tracks a Stripe Checkout Session initiated for a top-up.

  The session progresses through `:open` → `:complete`, `:expired`, or `:failed`.
  Once `:complete`, the Stripe webhook handler calls `record_stripe_event/5`
  which posts the matching `LedgerEntry`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stripe_checkout_sessions" do
    field(:session_id, :string)

    belongs_to(:organization, Harmont.Orgs.Organization)
    belongs_to(:initiated_by_user, Harmont.Accounts.User)

    field(:amount_cents, :integer)
    field(:status, Ecto.Enum, values: [:open, :complete, :expired, :failed], default: :open)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:session_id, :organization_id, :initiated_by_user_id, :amount_cents]
  @optional [:status]

  @doc "Changeset for creating or updating a Stripe Checkout Session record."
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint(:session_id,
      name: :stripe_checkout_sessions_session_id_index,
      message: "session already recorded"
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:initiated_by_user_id)
  end
end
