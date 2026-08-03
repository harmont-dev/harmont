defmodule Harmont.Vcs.WebhookDelivery do
  @moduledoc """
  Provider-agnostic webhook dedup row (`vcs_webhook_delivery`). Replaces
  `Harmont.Github.WebhookDelivery`. Uniqueness is per `(provider, delivery_id)`
  since delivery ids are only unique within a provider.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "vcs_webhook_delivery" do
    field(:provider, :string)
    field(:delivery_id, :string)
    field(:event, :string)
    field(:received_at, :utc_datetime_usec)
  end

  @doc "Changeset for reserving a delivery id."
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:provider, :delivery_id, :event, :received_at])
    |> validate_required([:provider, :delivery_id, :event, :received_at])
    |> unique_constraint([:provider, :delivery_id], name: :unique_vcs_webhook_delivery)
  end
end
