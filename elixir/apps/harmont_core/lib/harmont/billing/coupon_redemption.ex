defmodule Harmont.Billing.CouponRedemption do
  @moduledoc """
  Records that an organization redeemed a coupon.

  The unique index on `(coupon_id, org_id)` makes redemption idempotent:
  a concurrent second redemption attempt by the same org will hit the
  unique constraint, letting `redeem_coupon/5` return `:already_claimed`
  rather than double-crediting.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "coupon_redemptions" do
    belongs_to(:coupon, Harmont.Billing.Coupon)
    belongs_to(:organization, Harmont.Orgs.Organization)
    belongs_to(:redeemed_by_user, Harmont.Accounts.User)
    field(:credit_cents, :integer)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:coupon_id, :organization_id, :redeemed_by_user_id, :credit_cents]

  @doc "Changeset for inserting a coupon redemption record."
  def changeset(redemption, attrs) do
    redemption
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:coupon_id, :organization_id],
      name: :coupon_redemptions_coupon_id_organization_id_index,
      message: "already claimed by this organization"
    )
    |> foreign_key_constraint(:coupon_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:redeemed_by_user_id)
  end
end
