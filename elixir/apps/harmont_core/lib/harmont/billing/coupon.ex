defmodule Harmont.Billing.Coupon do
  @moduledoc """
  A promotional coupon that grants a credit to an organization on redemption.

  `max_redemptions` limits how many distinct orgs may redeem the coupon.
  `redemptions_used` is incremented atomically inside the redemption transaction.
  `expires_at`, when set, prevents redemption on or after that timestamp.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "coupons" do
    field(:code, :string)
    field(:credit_cents, :integer)
    field(:max_redemptions, :integer)
    field(:redemptions_used, :integer, default: 0)
    field(:expires_at, :utc_datetime_usec)

    belongs_to(:created_by_user, Harmont.Accounts.User)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:code, :credit_cents, :max_redemptions, :created_by_user_id]
  @optional [:redemptions_used, :expires_at]

  @doc "Changeset for creating a coupon."
  def changeset(coupon, attrs) do
    coupon
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:credit_cents, greater_than: 0)
    |> validate_number(:max_redemptions, greater_than: 0)
    |> unique_constraint(:code)
    |> foreign_key_constraint(:created_by_user_id)
  end
end
