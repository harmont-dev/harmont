defmodule Harmont.Billing.LedgerEntry do
  @moduledoc """
  An immutable ledger entry representing a credit or debit for an organization.

  Debits are negative `amount_cents`; credits are positive. The ledger is
  append-only: rows are never updated or deleted. The current balance is the
  `SUM(amount_cents)` for an org.

  ## Sources

  | source              | sign | trigger                          |
  |---------------------|------|----------------------------------|
  | `:stripe_topup`     | +    | Stripe checkout session complete |
  | `:coupon_redemption`| +    | coupon redeemed by org           |
  | `:admin_grant`      | +    | manual admin credit              |
  | `:vm_lease_debit`   | -    | VM lease finished                |
  | `:refund`           | +    | refund issued                    |
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ledger_entries" do
    belongs_to(:organization, Harmont.Orgs.Organization)

    field(:amount_cents, :integer)

    field(:source, Ecto.Enum,
      values: [:stripe_topup, :coupon_redemption, :admin_grant, :vm_lease_debit, :refund]
    )

    field(:description, :string)

    # Optional links to the originating rows (one is populated per entry type)
    field(:vm_lease_id, :binary_id)
    field(:coupon_redemption_id, :binary_id)
    field(:stripe_webhook_event_id, :binary_id)
    field(:granted_by_user_id, :binary_id)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:organization_id, :amount_cents, :source]
  @optional [
    :description,
    :vm_lease_id,
    :coupon_redemption_id,
    :stripe_webhook_event_id,
    :granted_by_user_id
  ]

  @doc "Changeset for inserting a new ledger entry."
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:granted_by_user_id)
  end
end
