defmodule HarmontApi.Controllers.StripeWebhookController do
  @moduledoc """
  Receives Stripe webhook events at `POST /api/v0/stripe/webhook`.

  This endpoint is PUBLIC — it carries no Harmont bearer and is not org-scoped.
  It is authenticated by Stripe's signature instead: the `Stripe-Signature`
  header is verified against the exact signed bytes of the request body and the
  endpoint's webhook signing secret. Only a signature failure yields a 400;
  every event we successfully verify returns 200 so Stripe stops retrying it.

  ## Raw body

  Signature verification must run over the literal wire bytes Stripe signed, not
  a re-encoded `Plug.Parsers` round-trip. `HarmontWeb.CacheBodyReader` (wired
  into the endpoint's `Plug.Parsers`) stashes those bytes under
  `conn.assigns.raw_body` for this path — exactly as the GitHub webhook
  (`HarmontWeb.GithubWebhook`) reads them. We reverse-and-join that newest-first
  iolist before handing it to the Stripe wrapper.

  ## Idempotency

  Exactly-once credit posting comes entirely from
  `Harmont.Billing.record_stripe_event/5` (Plan 2): it inserts the event row
  (unique `stripe_event_id` → `:already_seen` WITHOUT running the side effect),
  runs the side effect, and stamps `processed_at` — all in ONE transaction. A
  raise inside the side effect rolls the whole thing back, so Stripe's retry
  reprocesses cleanly. This controller only supplies the side-effect function
  and returns 200 for both `:new` and `:already_seen`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Harmont.Billing
  alias Harmont.Billing.StripeWebhookEvent
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.StripeWebhookResponse

  tags(["billing"])

  operation(:handle,
    summary: "Receive a Stripe webhook event",
    description:
      "Receives a Stripe webhook event and, for `checkout.session.completed`, " <>
        "posts the matching credit to the organization's ledger and marks the " <>
        "checkout session complete. **Not** bearer-authenticated: the request is " <>
        "authenticated by Stripe's `Stripe-Signature` header, verified against " <>
        "the raw request body and the endpoint's webhook signing secret. Credit " <>
        "posting is idempotent — replaying the same event id posts the credit " <>
        "only once. Returns 200 for any verified event (handled or not) so " <>
        "Stripe stops retrying; a signature failure returns 400.",
    operation_id: "stripeWebhook",
    "x-internal": true,
    security: [],
    responses: [
      ok: {"The event was verified and recorded", "application/json", StripeWebhookResponse},
      bad_request: {"The Stripe signature did not verify", "application/json", ErrorSchema}
    ]
  )

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    raw_body = raw_body(conn)
    sig_header = conn |> get_req_header("stripe-signature") |> List.first()
    secret = webhook_secret()

    case HarmontApi.Stripe.impl().construct_webhook_event(raw_body, sig_header, secret) do
      {:ok, event} ->
        {:ok, _outcome} =
          Billing.record_stripe_event(
            event["id"],
            event["type"],
            raw_body,
            side_effect_fun(event),
            Repo
          )

        json(conn, %{status: "ok"})

      {:error, _reason} ->
        EndpointError.send_envelope(conn, 400,
          type: "validation_failed",
          code: "stripe_signature_invalid",
          message: "The Stripe-Signature header did not verify against the request body.",
          doc_url: "https://docs.harmont.dev/api/errors/stripe-signature-invalid"
        )
    end
  end

  # Builds the side-effect function `record_stripe_event/5` runs (at most once
  # per event id) inside its transaction. `checkout.session.completed` posts the
  # credit + marks the session complete ONLY when the session is actually paid;
  # every other event type is a no-op (still recorded, so Stripe stops
  # retrying).
  #
  # `checkout.session.completed` fires for BOTH the synchronous card path
  # (`payment_status == "paid"`) and delayed-notification methods that complete
  # the session before the money settles (`"unpaid"` / `"processing"`). We must
  # not hand out free credit for the latter: crediting is gated on
  # `payment_status == "paid"`. For a still-unpaid completed session we leave it
  # `:open` and wait for `checkout.session.async_payment_succeeded` (credit) or
  # `checkout.session.async_payment_failed` (settle `:failed`).
  defp side_effect_fun(%{"type" => "checkout.session.completed"} = event) do
    session_id = get_in(event, ["data", "object", "id"])
    payment_status = get_in(event, ["data", "object", "payment_status"])

    fn %StripeWebhookEvent{} = event_row ->
      complete_checkout(session_id, payment_status, event_row)
    end
  end

  # The async (delayed-notification) payment finally cleared. Credit the
  # still-`:open` session and flip it to `:complete`, reusing the same
  # `:open`-only / session-status idempotency guard as the completed path so it
  # can never double-credit alongside a paid `completed` event.
  defp side_effect_fun(%{"type" => "checkout.session.async_payment_succeeded"} = event) do
    session_id = get_in(event, ["data", "object", "id"])

    fn %StripeWebhookEvent{} = event_row ->
      credit_checkout_session(session_id, event_row)
    end
  end

  defp side_effect_fun(%{"type" => "checkout.session.expired"} = event) do
    session_id = get_in(event, ["data", "object", "id"])

    fn %StripeWebhookEvent{} ->
      settle_unpaid_session(session_id, :expired)
    end
  end

  defp side_effect_fun(%{"type" => "checkout.session.async_payment_failed"} = event) do
    session_id = get_in(event, ["data", "object", "id"])

    fn %StripeWebhookEvent{} ->
      settle_unpaid_session(session_id, :failed)
    end
  end

  defp side_effect_fun(event) do
    fn %StripeWebhookEvent{} ->
      Logger.info("stripe webhook: ignoring unhandled event type #{inspect(event["type"])}")
      :ok
    end
  end

  # Handles `checkout.session.completed`. The session is paid synchronously only
  # when `payment_status == "paid"` (the card path): credit then. Any other
  # value (`"unpaid"` / `"processing"`, a delayed-notification method) means the
  # money has NOT settled — record the event so Stripe stops retrying, but post
  # no credit and leave the session `:open` for the later async_payment_*
  # outcome to resolve.
  defp complete_checkout(session_id, "paid", event_row) do
    credit_checkout_session(session_id, event_row)
  end

  defp complete_checkout(session_id, payment_status, %StripeWebhookEvent{}) do
    Logger.info(
      "stripe webhook: checkout.session.completed for #{inspect(session_id)} has " <>
        "payment_status #{inspect(payment_status)} (not \"paid\"); leaving session open " <>
        "and posting no credit until the async payment settles"
    )

    :ok
  end

  # Posts the top-up credit and marks the checkout session complete. Runs inside
  # the `record_stripe_event/5` transaction: any raise here rolls the whole
  # event back, so Stripe retries. Shared by the paid `completed` path and the
  # `async_payment_succeeded` path.
  #
  # Two layers of idempotency:
  #   1. `record_stripe_event/5` dedupes on `stripe_event_id` (replaying the SAME
  #      event id posts no second credit).
  #   2. This session-status guard: distinct event ids can map to ONE checkout
  #      session (Stripe emits e.g. both `checkout.session.completed` and
  #      `checkout.session.async_payment_succeeded`, and the dashboard can resend
  #      a fresh event id). Crediting on each would double-credit. We credit only
  #      while the session is still `:open` and flip it to `:complete`; any later
  #      event for an already-`:complete` session is a no-op.
  defp credit_checkout_session(session_id, %StripeWebhookEvent{id: event_id}) do
    case Repo.get_by(Billing.StripeCheckoutSession, session_id: session_id) do
      nil ->
        # No matching session on file. Record the event (so Stripe stops
        # retrying) but post no credit — we cannot attribute it.
        Logger.warning(
          "stripe webhook: paid checkout event for unknown session #{inspect(session_id)}"
        )

        :ok

      %{status: :open} = session ->
        {:ok, _entry} =
          Billing.insert_entry(
            %{
              organization_id: session.organization_id,
              amount_cents: session.amount_cents,
              source: :stripe_topup,
              description: "Stripe top-up",
              stripe_webhook_event_id: event_id
            },
            Repo
          )

        {:ok, _session} = Billing.mark_checkout_session(session, :complete, Repo)
        :ok

      %{status: status} ->
        # Already settled (or otherwise non-open) — a second event id for the
        # same session. Record the event but post no further credit.
        Logger.info(
          "stripe webhook: checkout session #{inspect(session_id)} already #{status}; " <>
            "skipping duplicate credit"
        )

        :ok
    end
  end

  # Marks an unpaid checkout session terminal (:expired or :failed) without
  # posting any credit. Only an :open session transitions; a session that
  # already settled (:complete) or is already terminal is left untouched, so a
  # late expiry/failure event can never clobber a paid top-up. Runs inside the
  # record_stripe_event/5 transaction.
  defp settle_unpaid_session(session_id, status) do
    case Repo.get_by(Billing.StripeCheckoutSession, session_id: session_id) do
      nil ->
        Logger.warning(
          "stripe webhook: #{status} event for unknown session #{inspect(session_id)}"
        )

        :ok

      %{status: :open} = session ->
        {:ok, _session} = Billing.mark_checkout_session(session, status, Repo)
        :ok

      %{status: existing} ->
        Logger.info(
          "stripe webhook: checkout session #{inspect(session_id)} already #{existing}; " <>
            "ignoring #{status} event"
        )

        :ok
    end
  end

  # Reverse-and-join the newest-first raw-body iolist cached by
  # `HarmontWeb.CacheBodyReader` (mirrors `HarmontWeb.GithubWebhook`).
  defp raw_body(conn), do: IO.iodata_to_binary(Enum.reverse(conn.assigns[:raw_body] || []))

  defp webhook_secret do
    :harmont_api
    |> Application.get_env(:stripe, [])
    |> Keyword.get(:webhook_secret)
  end
end
