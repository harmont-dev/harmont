defmodule Harmont.Billing.StripeWebhookEvent do
  @moduledoc """
  Idempotency record for processed Stripe webhook events.

  Each row represents one Stripe event that has been received and processed.
  The unique index on `stripe_event_id` ensures exactly-once delivery:
  a duplicate webhook delivery returns `:already_seen` without re-running
  the side effect.

  `processed_at` is stamped only after the side-effect function returns
  successfully; if the function raises, the whole transaction rolls back and
  the row is absent, so Stripe's retry will reprocess it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stripe_webhook_events" do
    field(:stripe_event_id, :string)
    field(:event_type, :string)
    field(:payload, :string)
    field(:processed_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:stripe_event_id, :event_type, :payload]
  @optional [:processed_at]

  @doc "Changeset for inserting a Stripe webhook event record."
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:stripe_event_id,
      name: :stripe_webhook_events_stripe_event_id_index,
      message: "already seen"
    )
  end
end
