defmodule Harmont.Integration.BillingEdgeE2ETest do
  @moduledoc """
  End-to-end billing checkout -> webhook -> credit through the REAL composed
  endpoint.

  This drives the full Plan-5 billing loop against `HarmontWeb.Endpoint` — the
  single endpoint that mounts `HarmontApi.Router` at `/api/v0` — using
  `Phoenix.ConnTest` (no live listener). It proves the composed system works in
  one piece:

    1. `POST /api/v0/billing/checkout/:org {amount_cents: 5000}` (bearer,
       org-scoped) -> 200 + a hosted `checkout_url`; an `:open`
       `stripe_checkout_session` row is recorded (Stripe boundary is the
       in-process `HarmontApi.StripeFake`).
    2. `POST /api/v0/stripe/webhook` with a `checkout.session.completed` event
       for that session (PUBLIC, Stripe-signature authed) -> 200. The raw body
       is signed-by-bytes: the endpoint's `HarmontWeb.CacheBodyReader` caches
       the exact wire bytes for `/api/v0/stripe/webhook` under
       `conn.assigns.raw_body`, which the controller reverse-joins and the
       `StripeFake` decodes as the event. A non-"bad" `Stripe-Signature` header
       passes the fake's verification.
    3. `GET /api/v0/billing/balance/:org` (bearer, org-scoped) -> 200; balance
       is the 5000 credit posted by the webhook side effect.
    4. Re-POST the SAME webhook event id -> 200; balance is STILL 5000 — the
       `Harmont.Billing.record_stripe_event/5` single-transaction idempotency
       guarantee means the credit posts exactly once.

  Everything below the HTTP edge — the `:authed` bearer plug, the `OrgScope`
  tenancy plug, the endpoint's `CacheBodyReader` raw-body caching, the Plan-2
  `Harmont.Billing` context, and the idempotent `record_stripe_event/5` — is the
  real composed system against Postgres. Only the Stripe network/signing
  boundary is faked. The session bearer is minted directly via
  `Harmont.Accounts.create_session_token` to keep the test focused on billing.
  """
  use HarmontWeb.ConnCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Billing.StripeCheckoutSession
  alias Harmont.Orgs
  alias Harmont.Repo

  defp seed_user_org do
    {:ok, user} =
      Repo.insert(User.changeset(%User{}, %{name: "BillE2E", email: "billing-e2e@harmont.dev"}))

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"}, Repo)
    {:ok, _membership} = Orgs.add_member(org, user, :member, Repo)

    {raw_token, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    {user, org, "Bearer " <> raw_token}
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  # POST the webhook through the real endpoint. We send the raw JSON body and a
  # non-"bad" Stripe-Signature; the endpoint's CacheBodyReader caches the raw
  # bytes for this path and the StripeFake decodes them as the event.
  defp post_webhook(event, sig) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", sig)
    |> post("/api/v0/stripe/webhook", Jason.encode!(event))
  end

  test "checkout -> webhook -> balance, idempotent on replay, through HarmontWeb.Endpoint", %{
    conn: conn
  } do
    {_user, org, bearer} = seed_user_org()

    # 1. Start a checkout for $50.00 -> 200 + a hosted checkout URL.
    checkout_conn =
      conn
      |> put_req_header("authorization", bearer)
      |> post_json("/api/v0/billing/checkout/acme", %{"amount_cents" => 5000})

    assert checkout_conn.status == 200
    checkout_body = json_response(checkout_conn, 200)
    assert is_binary(checkout_body["checkout_url"]) and checkout_body["checkout_url"] != ""

    # An :open checkout session row was recorded for this org.
    session = Repo.get_by!(StripeCheckoutSession, organization_id: org.id)
    assert session.status == :open
    assert session.amount_cents == 5000

    # 2. Stripe fires checkout.session.completed for that session -> 200.
    event_id = "evt_#{System.unique_integer([:positive])}"

    event = %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "data" => %{"object" => %{"id" => session.session_id}}
    }

    webhook_conn = post_webhook(event, "valid-sig")
    assert webhook_conn.status == 200
    assert json_response(webhook_conn, 200) == %{"status" => "ok"}

    # The session is now complete.
    assert Repo.get!(StripeCheckoutSession, session.id).status == :complete

    # 3. Balance reflects the 5000-cent credit.
    balance_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> get("/api/v0/billing/balance/acme")

    assert balance_conn.status == 200
    assert json_response(balance_conn, 200)["balance_cents"] == 5000

    # 4. Replay the SAME webhook event id -> 200, but the credit posts only once.
    replay_conn = post_webhook(event, "valid-sig")
    assert replay_conn.status == 200
    assert json_response(replay_conn, 200) == %{"status" => "ok"}

    # Balance unchanged — idempotent via record_stripe_event/5.
    assert Billing.balance(org.id, Repo) == 5000

    balance_again =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> get("/api/v0/billing/balance/acme")

    assert json_response(balance_again, 200)["balance_cents"] == 5000
  end
end
