defmodule HarmontApi.StripeTest do
  @moduledoc """
  Unit tests for the real `HarmontApi.Stripe` wrapper's nil-config behaviour.

  In prod, `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` are OPTIONAL: when
  they are absent the app boots with billing unconfigured. These tests pin the
  contract the controllers rely on for that state — the wrapper short-circuits
  to `{:error, :unconfigured}` BEFORE handing a nil key/secret to
  `stripity_stripe`, so checkout returns 503 `billing_unconfigured` and the
  webhook returns 400 rather than crashing.

  The rest of the suite exercises billing through `HarmontApi.StripeFake`; this
  is the only test that drives the real module directly, so it does not touch
  Stripe's network — both branches return before any `stripity_stripe` call.
  """
  use ExUnit.Case, async: false

  alias HarmontApi.Stripe

  describe "create_checkout_session/1 when the Stripe API key is absent" do
    setup do
      original = Application.get_env(:stripity_stripe, :api_key)
      on_exit(fn -> restore(:stripity_stripe, :api_key, original) end)
      :ok
    end

    test "nil api_key returns {:error, :unconfigured}" do
      Application.put_env(:stripity_stripe, :api_key, nil)

      assert {:error, :unconfigured} =
               Stripe.create_checkout_session(%{
                 amount_cents: 1000,
                 success_url: "https://app.harmont.dev/billing/success",
                 cancel_url: "https://app.harmont.dev/billing/cancel"
               })
    end

    test "blank api_key returns {:error, :unconfigured}" do
      Application.put_env(:stripity_stripe, :api_key, "")

      assert {:error, :unconfigured} =
               Stripe.create_checkout_session(%{
                 amount_cents: 1000,
                 success_url: "https://app.harmont.dev/billing/success",
                 cancel_url: "https://app.harmont.dev/billing/cancel"
               })
    end
  end

  describe "construct_webhook_event/3 when the webhook secret is absent" do
    test "nil secret returns {:error, :unconfigured}" do
      assert {:error, :unconfigured} =
               Stripe.construct_webhook_event("{}", "sig", nil)
    end

    test "blank secret returns {:error, :unconfigured}" do
      assert {:error, :unconfigured} =
               Stripe.construct_webhook_event("{}", "sig", "")
    end
  end

  describe "expand_event/1 normalises the real struct shape to string keys" do
    # NOTE: `alias HarmontApi.Stripe` at the module level shadows the
    # `Stripe.*` namespace from stripity_stripe in this describe block, so we
    # assign the stripity_stripe module references to local variables instead of
    # using struct literals directly.
    test "a checkout.session.completed event exposes object id + payment_status by STRING key" do
      # Mirrors what stripity_stripe v3 hands us: a %Stripe.Event{} whose
      # data.object is a %Stripe.Checkout.Session{} struct (atom-keyed). The
      # webhook controller reads this with STRING keys, so the normaliser MUST
      # stringify all the way down to the object's own keys.
      stripe_event_mod = :"Elixir.Stripe.Event"
      stripe_session_mod = :"Elixir.Stripe.Checkout.Session"

      session =
        struct(stripe_session_mod, %{
          id: "cs_test_abc",
          payment_status: "paid",
          status: "complete",
          metadata: %{"org_id" => "org_xyz"}
        })

      event =
        struct(stripe_event_mod, %{
          id: "evt_test_123",
          type: "checkout.session.completed",
          data: %{object: session}
        })

      expanded = Stripe.expand_event(event)

      assert expanded["id"] == "evt_test_123"
      assert expanded["type"] == "checkout.session.completed"
      assert get_in(expanded, ["data", "object", "id"]) == "cs_test_abc"
      assert get_in(expanded, ["data", "object", "payment_status"]) == "paid"
      # Nested maps that were already string-keyed stay intact.
      assert get_in(expanded, ["data", "object", "metadata", "org_id"]) == "org_xyz"
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
