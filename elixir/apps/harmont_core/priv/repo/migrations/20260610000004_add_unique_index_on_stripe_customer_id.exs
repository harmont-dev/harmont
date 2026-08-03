defmodule Harmont.Repo.Migrations.AddUniqueIndexOnStripeCustomerId do
  @moduledoc """
  Adds a partial unique index on `organizations(stripe_customer_id)`.

  Defense in depth against a concurrent first-checkout race minting two Stripe
  Customers for one org: even if two requests both create a customer before
  either persists, the DB now refuses the second persist instead of
  last-write-wins clobbering the first. Partial (`WHERE stripe_customer_id IS
  NOT NULL`) so the many orgs that never pay — all NULL — are unconstrained.
  """
  use Ecto.Migration

  def change do
    create unique_index(:organizations, [:stripe_customer_id],
             where: "stripe_customer_id IS NOT NULL",
             name: :organizations_stripe_customer_id_index
           )
  end
end
