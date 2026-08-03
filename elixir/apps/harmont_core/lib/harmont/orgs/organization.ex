defmodule Harmont.Orgs.Organization do
  @moduledoc "An organization (tenant) in Harmont. Slug is unique and URL-safe."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field(:name, :string)
    field(:slug, :string)
    field(:url, :string)
    field(:stripe_customer_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating or updating an organization."
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :url, :stripe_customer_id])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
    |> unique_constraint(:stripe_customer_id)
  end
end
