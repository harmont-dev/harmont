defmodule Harmont.Vcs.WebhookDeliveryTest do
  use ExUnit.Case, async: true

  alias Harmont.Vcs.WebhookDelivery

  test "changeset requires provider, delivery_id, event, received_at" do
    cs =
      WebhookDelivery.changeset(%{
        provider: "github",
        delivery_id: "d-1",
        event: "push",
        received_at: DateTime.utc_now()
      })

    assert cs.valid?
    refute WebhookDelivery.changeset(%{provider: "github"}).valid?
  end
end
