defmodule Harmont.Repo.Migrations.AddStripeCustomerIdToOrganizations do
  @moduledoc """
  Adds a nullable `stripe_customer_id` to organizations.

  Populated lazily on an org's first Stripe checkout and reused thereafter, so
  payments attach to one persistent Stripe Customer per org. Nullable: orgs that
  never pay keep it null, and billing stays optional (no key configured → no
  customer).
  """
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :stripe_customer_id, :string
    end
  end
end
