defmodule HarmontApi.StripeWebhookTest do
  @moduledoc """
  End-to-end tests for `POST /api/v0/stripe/webhook` (public, Stripe-signature
  authed).

  The route, `Harmont.Billing.record_stripe_event/5` idempotency, and the credit
  posting all run for real against Postgres. The Stripe boundary is the
  in-process `HarmontApi.StripeFake`, which decodes the raw body as the event
  and treats a `Stripe-Signature` of `"bad"` as a verification failure — so the
  tests synthesise events as plain JSON with no real Stripe signing.

  The bare router test does not run the endpoint's `CacheBodyReader`, so each
  request sets `conn.assigns.raw_body` explicitly (newest-first iolist, exactly
  the shape `CacheBodyReader` produces and the controller reverse-joins).
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Billing.LedgerEntry
  alias Harmont.Billing.StripeCheckoutSession
  alias Harmont.Billing.StripeWebhookEvent
  alias Harmont.Orgs

  import Ecto.Query, only: [from: 2]

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp seed_session(slug, amount_cents) do
    user = create_user("wh-#{slug}@harmont.dev")
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: slug}, Repo)

    session_id = "cs_test_#{System.unique_integer([:positive])}"

    {:ok, session} =
      Billing.record_checkout_session(
        %{
          session_id: session_id,
          org_id: org.id,
          initiated_by_user_id: user.id,
          amount_cents: amount_cents,
          status: :open
        },
        Repo
      )

    %{org: org, session: session, session_id: session_id}
  end

  defp checkout_completed_event(event_id, session_id, payment_status \\ "paid") do
    %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "data" => %{"object" => %{"id" => session_id, "payment_status" => payment_status}}
    }
  end

  defp async_payment_event(event_id, session_id, type) do
    %{
      "id" => event_id,
      "type" => type,
      "data" => %{"object" => %{"id" => session_id}}
    }
  end

  # Drive the webhook through the bare router, mirroring the billing_test
  # convention but additionally stashing the raw body the controller reads.
  defp post_webhook(event, sig) do
    body = Jason.encode!(event)

    :post
    |> Plug.Test.conn("/api/v0/stripe/webhook", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("stripe-signature", sig)
    |> Plug.Conn.assign(:raw_body, [body])
    |> Plug.Conn.fetch_query_params()
    |> HarmontApi.Router.call(HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp credit_count(org_id) do
    Repo.aggregate(
      from(e in LedgerEntry, where: e.organization_id == ^org_id and e.source == :stripe_topup),
      :count
    )
  end

  # ---------------------------------------------------------------------------
  # checkout.session.completed
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — checkout.session.completed" do
    test "posts a credit, completes the session, stamps the event" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-ok", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"
      event = checkout_completed_event(event_id, session_id)

      conn = post_webhook(event, "valid-sig")

      assert conn.status == 200
      assert decode(conn) == %{"status" => "ok"}

      # A single stripe_topup credit of the session amount.
      assert Billing.balance(org.id, Repo) == 5000
      assert credit_count(org.id) == 1

      # The checkout session is now complete.
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete

      # The event row carries a processed_at stamp.
      recorded = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      assert recorded.event_type == "checkout.session.completed"
      refute is_nil(recorded.processed_at)
    end

    test "is idempotent — replaying the same event id credits once" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-idem", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"
      event = checkout_completed_event(event_id, session_id)

      assert post_webhook(event, "valid-sig").status == 200
      assert post_webhook(event, "valid-sig").status == 200

      # The second delivery is :already_seen — the credit posts only once.
      assert credit_count(org.id) == 1
      assert Billing.balance(org.id, Repo) == 5000
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end

    test "two DISTINCT event ids for the SAME session credit only once" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-2evt", 5000)

      # Distinct event ids → the stripe_event_id dedupe does NOT cover this; the
      # session-status guard must. (Mirrors Stripe resending a fresh event id, or
      # a second completed-style event for one checkout session.)
      first = checkout_completed_event("evt_#{System.unique_integer([:positive])}", session_id)
      second = checkout_completed_event("evt_#{System.unique_integer([:positive])}", session_id)

      assert post_webhook(first, "valid-sig").status == 200
      assert post_webhook(second, "valid-sig").status == 200

      # Credit posts exactly once; the session is complete after the first event,
      # so the second (distinct) event is a no-op.
      assert credit_count(org.id) == 1
      assert Billing.balance(org.id, Repo) == 5000
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end
  end

  # ---------------------------------------------------------------------------
  # checkout.session.completed — delayed-notification (unpaid) gating
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — completed with payment_status != paid" do
    test "posts no credit and leaves the session open when payment_status is unpaid" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-unpaid", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"
      event = checkout_completed_event(event_id, session_id, "unpaid")

      conn = post_webhook(event, "valid-sig")

      assert conn.status == 200
      assert decode(conn) == %{"status" => "ok"}

      # No credit yet — the money has not settled.
      assert credit_count(org.id) == 0
      assert Billing.balance(org.id, Repo) == 0

      # The session stays open so the later async outcome can resolve it.
      assert Repo.get!(StripeCheckoutSession, session.id).status == :open

      # The event is still recorded + stamped so Stripe stops retrying.
      recorded = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      refute is_nil(recorded.processed_at)
    end

    test "async_payment_succeeded after an unpaid completed credits exactly once" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-async-ok", 5000)

      # 1. completed arrives unpaid → no credit, session stays open.
      unpaid =
        checkout_completed_event(
          "evt_#{System.unique_integer([:positive])}",
          session_id,
          "unpaid"
        )

      assert post_webhook(unpaid, "valid-sig").status == 200
      assert credit_count(org.id) == 0

      # 2. async_payment_succeeded clears the payment → credit posts once.
      succeeded =
        async_payment_event(
          "evt_#{System.unique_integer([:positive])}",
          session_id,
          "checkout.session.async_payment_succeeded"
        )

      assert post_webhook(succeeded, "valid-sig").status == 200
      assert credit_count(org.id) == 1
      assert Billing.balance(org.id, Repo) == 5000
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end

    test "async_payment_failed after an unpaid completed posts no credit and fails the session" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-async-fail", 5000)

      unpaid =
        checkout_completed_event(
          "evt_#{System.unique_integer([:positive])}",
          session_id,
          "unpaid"
        )

      assert post_webhook(unpaid, "valid-sig").status == 200

      failed =
        async_payment_event(
          "evt_#{System.unique_integer([:positive])}",
          session_id,
          "checkout.session.async_payment_failed"
        )

      assert post_webhook(failed, "valid-sig").status == 200
      assert credit_count(org.id) == 0
      assert Billing.balance(org.id, Repo) == 0
      assert Repo.get!(StripeCheckoutSession, session.id).status == :failed
    end
  end

  describe "POST /api/v0/stripe/webhook — async_payment_succeeded" do
    test "credits a paid completed session once even if succeeded also arrives" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-async-dup", 5000)

      # Paid card path completes + credits.
      paid = checkout_completed_event("evt_#{System.unique_integer([:positive])}", session_id)
      assert post_webhook(paid, "valid-sig").status == 200
      assert credit_count(org.id) == 1

      # A stray async_payment_succeeded for the same (now complete) session is a
      # no-op — the session-status guard prevents a double credit.
      succeeded =
        async_payment_event(
          "evt_#{System.unique_integer([:positive])}",
          session_id,
          "checkout.session.async_payment_succeeded"
        )

      assert post_webhook(succeeded, "valid-sig").status == 200
      assert credit_count(org.id) == 1
      assert Billing.balance(org.id, Repo) == 5000
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end
  end

  # ---------------------------------------------------------------------------
  # checkout.session.expired
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — checkout.session.expired" do
    test "marks an open session expired and posts no credit" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-exp", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"

      event = %{
        "id" => event_id,
        "type" => "checkout.session.expired",
        "data" => %{"object" => %{"id" => session_id}}
      }

      conn = post_webhook(event, "valid-sig")

      assert conn.status == 200
      assert decode(conn) == %{"status" => "ok"}
      assert credit_count(org.id) == 0
      assert Repo.get!(StripeCheckoutSession, session.id).status == :expired

      # The event is recorded and stamped, just like the completed path.
      recorded = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      assert recorded.event_type == "checkout.session.expired"
      refute is_nil(recorded.processed_at)
    end

    test "leaves an already-complete session untouched" do
      %{session: session, session_id: session_id} = seed_session("wh-exp-c", 5000)
      {:ok, _} = Billing.mark_checkout_session(session, :complete, Repo)

      event = %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "checkout.session.expired",
        "data" => %{"object" => %{"id" => session_id}}
      }

      assert post_webhook(event, "valid-sig").status == 200
      # Still complete — an expiry event must not clobber a settled session.
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end
  end

  # ---------------------------------------------------------------------------
  # checkout.session.async_payment_failed
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — async_payment_failed" do
    test "marks an open session failed and posts no credit" do
      %{org: org, session: session, session_id: session_id} = seed_session("wh-fail", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"

      event = %{
        "id" => event_id,
        "type" => "checkout.session.async_payment_failed",
        "data" => %{"object" => %{"id" => session_id}}
      }

      conn = post_webhook(event, "valid-sig")

      assert conn.status == 200
      assert decode(conn) == %{"status" => "ok"}
      assert credit_count(org.id) == 0
      assert Repo.get!(StripeCheckoutSession, session.id).status == :failed

      # The event is recorded and stamped, just like the expired/completed paths.
      recorded = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      assert recorded.event_type == "checkout.session.async_payment_failed"
      refute is_nil(recorded.processed_at)
    end

    test "leaves an already-complete session untouched" do
      %{session: session, session_id: session_id} = seed_session("wh-fail-c", 5000)
      {:ok, _} = Billing.mark_checkout_session(session, :complete, Repo)

      event = %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "checkout.session.async_payment_failed",
        "data" => %{"object" => %{"id" => session_id}}
      }

      assert post_webhook(event, "valid-sig").status == 200
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end
  end

  # ---------------------------------------------------------------------------
  # Signature failure
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — bad signature" do
    test "returns 400 and posts no credit" do
      %{org: org, session_id: session_id} = seed_session("wh-bad", 5000)
      event = checkout_completed_event("evt_#{System.unique_integer([:positive])}", session_id)

      conn = post_webhook(event, "bad")

      assert conn.status == 400
      assert credit_count(org.id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Unhandled event type
  # ---------------------------------------------------------------------------

  describe "POST /api/v0/stripe/webhook — unhandled event type" do
    test "returns 200, posts no credit, records the event" do
      %{org: org} = seed_session("wh-unhandled", 5000)
      event_id = "evt_#{System.unique_integer([:positive])}"

      event = %{
        "id" => event_id,
        "type" => "payment_intent.created",
        "data" => %{"object" => %{"id" => "pi_test"}}
      }

      conn = post_webhook(event, "valid-sig")

      assert conn.status == 200
      assert decode(conn) == %{"status" => "ok"}
      assert credit_count(org.id) == 0

      recorded = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      assert recorded.event_type == "payment_intent.created"
      refute is_nil(recorded.processed_at)
    end
  end
end
