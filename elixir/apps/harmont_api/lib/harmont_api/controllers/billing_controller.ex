defmodule HarmontApi.Controllers.BillingController do
  @moduledoc """
  Billing read endpoints, org-scoped by the `:org` path param (tenancy 404 via
  `HarmontApi.Plugs.OrgScope`).

  - `GET /billing/balance/:org` — the org's current balance in cents
    (`Harmont.Billing.balance/2`).
  - `GET /billing/transactions/:org` — the org's ledger entries, newest first,
    cursor-paginated (`Harmont.Billing.list_entries_query/1` + `Pagination`).
  - `GET /billing/usage/:org?from=&to=` — VM-lease usage aggregates over the
    half-open ISO-8601 window `[from, to)` (`Harmont.Billing.usage/4`).
  - `GET /billing/usage/:org/breakdown?from=&to=` — per-build VM-usage breakdown
    over the `[from, to)` window, grouped by build and broken down per job lease
    (`Harmont.Billing.usage_breakdown/4`).
  - `POST /billing/coupon/redeem/:org` — redeems a coupon for the org
    (`Harmont.Billing.redeem_coupon/5`).
  - `POST /billing/checkout/:org` — starts a Stripe Checkout Session for a
    credit top-up (`HarmontApi.Stripe` + `Harmont.Billing.record_checkout_session/2`).

  The org is taken from the `:org` path param (consistent with the other
  billing routes), not the request body: tenancy is resolved/authorized once
  by `OrgScope`, so the redeem body carries only the coupon `code`.

  Pure HTTP edge over the `Harmont.Billing` core context.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Harmont.Billing
  alias Harmont.Error
  alias Harmont.Orgs
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Pagination
  alias HarmontApi.Schemas.BalanceResponse
  alias HarmontApi.Schemas.CheckoutRequest
  alias HarmontApi.Schemas.CheckoutResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.RedeemCouponRequest
  alias HarmontApi.Schemas.RedeemCouponResponse
  alias HarmontApi.Schemas.TransactionList
  alias HarmontApi.Schemas.UsageBreakdownResponse
  alias HarmontApi.Schemas.UsageResponse
  alias HarmontApi.Schemas.UsageSeriesResponse

  # Accepted credit top-up bounds, in cents: $1.00 .. $10,000.00. Outside this
  # range a checkout request is rejected with 422 `invalid_amount` rather than
  # forwarded to Stripe.
  @min_amount_cents 100
  @max_amount_cents 1_000_000

  tags(["billing"])

  operation(:balance,
    summary: "Get an organization's balance",
    description:
      "Returns the organization's current balance in cents — the sum of every " <>
        "ledger entry (credits positive, debits negative). May be negative.",
    operation_id: "getBillingBalance",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    responses: [
      ok: {"The organization's balance", "application/json", BalanceResponse},
      not_found: {"No such organization", "application/json", ErrorSchema}
    ]
  )

  @spec balance(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def balance(conn, _params) do
    org = conn.assigns.org
    json(conn, %{balance_cents: Billing.balance(org.id, Repo)})
  end

  operation(:transactions,
    summary: "List an organization's ledger entries",
    description: "Returns the organization's ledger entries, newest first, cursor-paginated.",
    operation_id: "listBillingTransactions",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size (1–100, default 50)."
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description: "Opaque cursor from a previous page's `next_cursor`."
      ]
    ],
    responses: [
      ok: {"The organization's ledger entries", "application/json", TransactionList},
      not_found: {"No such organization", "application/json", ErrorSchema}
    ]
  )

  @spec transactions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def transactions(conn, params) do
    org = conn.assigns.org
    query = Billing.list_entries_query(org.id)
    {entries, next_cursor} = Pagination.paginate(query, params, Repo, order: :desc)

    json(conn, %{
      data: Enum.map(entries, &render_entry/1),
      next_cursor: next_cursor
    })
  end

  operation(:usage,
    summary: "Get an organization's VM usage",
    description:
      "Aggregates the organization's VM-lease usage over the half-open window " <>
        "`[from, to)` (both ISO-8601 timestamps): resource-seconds per " <>
        "dimension and the total billed cost in cents. Both `from` and `to` " <>
        "are required.",
    operation_id: "getBillingUsage",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      from: [
        in: :query,
        type: :string,
        required: true,
        description: "Window start (inclusive), ISO-8601."
      ],
      to: [
        in: :query,
        type: :string,
        required: true,
        description: "Window end (exclusive), ISO-8601."
      ]
    ],
    responses: [
      ok: {"The usage aggregates", "application/json", UsageResponse},
      unprocessable_entity: {"Missing or invalid time window", "application/json", ErrorSchema},
      not_found: {"No such organization", "application/json", ErrorSchema}
    ]
  )

  @spec usage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def usage(conn, params) do
    org = conn.assigns.org

    with {:ok, from} <- parse_ts(params["from"], "from"),
         {:ok, to} <- parse_ts(params["to"], "to"),
         :ok <- validate_window(from, to) do
      json(conn, Billing.usage(org.id, from, to, Repo))
    else
      {:error, message} ->
        EndpointError.send_envelope(conn, 422,
          type: "validation_failed",
          code: "billing_usage_window_invalid",
          message: message,
          doc_url: "https://docs.harmont.dev/api/errors/billing-usage-window-invalid"
        )
    end
  end

  operation(:usage_series,
    summary: "Per-day usage time-series",
    operation_id: "getBillingUsageSeries",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "Organization slug."],
      from: [
        in: :query,
        type: :string,
        required: true,
        description: "ISO-8601 window start (inclusive)."
      ],
      to: [
        in: :query,
        type: :string,
        required: true,
        description: "ISO-8601 window end (exclusive)."
      ]
    ],
    responses: [
      ok: {"Per-day usage buckets", "application/json", UsageSeriesResponse},
      unprocessable_entity: {"Invalid window", "application/json", ErrorSchema},
      not_found: {"No such organization", "application/json", ErrorSchema}
    ]
  )

  @spec usage_series(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def usage_series(conn, params) do
    org = conn.assigns.org

    with {:ok, from} <- parse_ts(params["from"], "from"),
         {:ok, to} <- parse_ts(params["to"], "to"),
         :ok <- validate_window(from, to) do
      json(conn, %{data: Billing.usage_series(org.id, from, to, Repo)})
    else
      {:error, message} ->
        EndpointError.send_envelope(conn, 422,
          type: "validation_failed",
          code: "billing_usage_window_invalid",
          message: message,
          doc_url: "https://docs.harmont.dev/api/errors/billing-usage-window-invalid"
        )
    end
  end

  operation(:usage_breakdown,
    summary: "Per-build VM usage breakdown",
    description:
      "Returns the organization's VM usage over the half-open `[from, to)` window " <>
        "(both ISO-8601), grouped by build (newest first) and broken down per job " <>
        "lease — pipeline, build number, job, VM handle, resource shape, duration " <>
        "and cost — so a charge can be traced to its source.",
    operation_id: "getBillingUsageBreakdown",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "Organization slug."],
      from: [
        in: :query,
        type: :string,
        required: true,
        description: "ISO-8601 window start (inclusive)."
      ],
      to: [
        in: :query,
        type: :string,
        required: true,
        description: "ISO-8601 window end (exclusive)."
      ]
    ],
    responses: [
      ok: {"Per-build usage breakdown", "application/json", UsageBreakdownResponse},
      unprocessable_entity: {"Invalid window", "application/json", ErrorSchema},
      not_found: {"No such organization", "application/json", ErrorSchema}
    ]
  )

  @spec usage_breakdown(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def usage_breakdown(conn, params) do
    org = conn.assigns.org

    with {:ok, from} <- parse_ts(params["from"], "from"),
         {:ok, to} <- parse_ts(params["to"], "to"),
         :ok <- validate_window(from, to) do
      json(conn, %{data: Billing.usage_breakdown(org.id, from, to, Repo)})
    else
      {:error, message} ->
        EndpointError.send_envelope(conn, 422,
          type: "validation_failed",
          code: "billing_usage_window_invalid",
          message: message,
          doc_url: "https://docs.harmont.dev/api/errors/billing-usage-window-invalid"
        )
    end
  end

  operation(:redeem_coupon,
    summary: "Redeem a coupon for an organization",
    description:
      "Redeems a coupon code for the organization identified by the path, " <>
        "crediting the org and returning the credit and resulting balance. The " <>
        "org is taken from the route; the body carries only the coupon `code`. " <>
        "Idempotent per org: a second redemption of the same coupon returns " <>
        "`409 coupon_already_claimed`.",
    operation_id: "redeemCoupon",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    request_body: {"The coupon to redeem", "application/json", RedeemCouponRequest},
    responses: [
      ok: {"The credit granted and resulting balance", "application/json", RedeemCouponResponse},
      not_found: {"No such organization or coupon", "application/json", ErrorSchema},
      conflict: {"The coupon was already redeemed by this org", "application/json", ErrorSchema},
      unprocessable_entity:
        {"The coupon is expired or exhausted", "application/json", ErrorSchema}
    ]
  )

  @spec redeem_coupon(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem_coupon(conn, params) do
    org = conn.assigns.org
    user = conn.assigns.current_user
    code = params["code"]

    case Billing.redeem_coupon(DateTime.utc_now(), user.id, org.id, code, Repo) do
      {:ok, cents} ->
        json(conn, %{credit_cents: cents, balance_cents: Billing.balance(org.id, Repo)})

      {:error, reason} ->
        send_coupon_error(conn, reason)
    end
  end

  operation(:checkout,
    summary: "Start a Stripe Checkout Session for a credit top-up",
    description:
      "Creates a Stripe Checkout Session crediting the organization identified " <>
        "by the path (`:org`) and returns the hosted checkout URL to redirect " <>
        "the customer to. The body carries only the top-up `amount_cents` " <>
        "(a positive integer within supported bounds). The credit itself is " <>
        "posted asynchronously when Stripe fires the matching webhook.",
    operation_id: "createCheckout",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    request_body: {"The top-up amount", "application/json", CheckoutRequest},
    responses: [
      ok: {"The hosted Stripe Checkout URL", "application/json", CheckoutResponse},
      unprocessable_entity: {"Invalid top-up amount", "application/json", ErrorSchema},
      not_found: {"No such organization", "application/json", ErrorSchema},
      bad_gateway: {"The billing provider is unavailable", "application/json", ErrorSchema},
      service_unavailable: {"Billing is not configured", "application/json", ErrorSchema}
    ]
  )

  @spec checkout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def checkout(conn, params) do
    org = conn.assigns.org
    user = conn.assigns.current_user

    case validate_amount(params["amount_cents"]) do
      {:ok, amount_cents} -> create_checkout(conn, org, user, amount_cents)
      {:error, :invalid_amount} -> send_invalid_amount(conn)
    end
  end

  defp create_checkout(conn, org, user, amount_cents) do
    stripe_config = Application.get_env(:harmont_api, :stripe, [])
    customer_id = ensure_customer(org)

    session_params =
      %{
        amount_cents: amount_cents,
        org: org,
        success_url: Keyword.get(stripe_config, :checkout_success_url),
        cancel_url: Keyword.get(stripe_config, :checkout_cancel_url),
        metadata: %{"org_id" => org.id}
      }
      |> maybe_put_customer(customer_id)

    case HarmontApi.Stripe.impl().create_checkout_session(session_params) do
      {:ok, %{id: session_id, url: url}} ->
        {:ok, _session} =
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

        json(conn, %{checkout_url: url})

      {:error, :unconfigured} ->
        EndpointError.send(conn, Error.new(:billing_unconfigured))

      {:error, _other} ->
        EndpointError.send(conn, Error.new(:billing_provider_error))
    end
  end

  # Returns the org's Stripe customer id, creating + persisting one on first use.
  # A creation failure is non-fatal: we log and return nil so the top-up still
  # proceeds as an anonymous session rather than blocking payment.
  #
  # `Orgs.ensure_stripe_customer_id/3` serializes on the org row, so two
  # concurrent first-checkouts can't each mint a Stripe Customer: the loser of
  # the row lock observes the winner's persisted id and never calls Stripe.
  defp ensure_customer(%{stripe_customer_id: id}) when is_binary(id), do: id

  defp ensure_customer(org) do
    create_fun = fn ->
      case HarmontApi.Stripe.impl().create_customer(%{
             name: org.name,
             metadata: %{"org_id" => org.id}
           }) do
        {:ok, %{id: id}} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end

    case Orgs.ensure_stripe_customer_id(org, create_fun, Repo) do
      {:ok, id} ->
        id

      {:error, reason} ->
        # Customer creation or persistence failed. Fall back to an anonymous
        # session rather than blocking payment.
        Logger.warning(
          "billing: could not resolve stripe customer for org " <>
            "#{inspect(org.id)}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp maybe_put_customer(params, nil), do: params
  defp maybe_put_customer(params, customer_id), do: Map.put(params, :customer, customer_id)

  # The top-up amount must be a positive integer within the supported bounds.
  defp validate_amount(amount)
       when is_integer(amount) and amount in @min_amount_cents..@max_amount_cents,
       do: {:ok, amount}

  defp validate_amount(_amount), do: {:error, :invalid_amount}

  defp send_invalid_amount(conn) do
    EndpointError.send_envelope(conn, 422,
      type: "validation_failed",
      code: "invalid_amount",
      message:
        "`amount_cents` must be a positive integer between " <>
          "#{@min_amount_cents} and #{@max_amount_cents}.",
      doc_url: "https://docs.harmont.dev/api/errors/invalid-amount"
    )
  end

  defp send_coupon_error(conn, :coupon_not_found) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "coupon_not_found",
      message: "No coupon with that code exists.",
      doc_url: "https://docs.harmont.dev/api/errors/coupon-not-found"
    )
  end

  defp send_coupon_error(conn, :coupon_expired) do
    EndpointError.send_envelope(conn, 422,
      type: "validation_failed",
      code: "coupon_expired",
      message: "This coupon has expired.",
      doc_url: "https://docs.harmont.dev/api/errors/coupon-expired"
    )
  end

  defp send_coupon_error(conn, :coupon_exhausted) do
    EndpointError.send_envelope(conn, 422,
      type: "validation_failed",
      code: "coupon_exhausted",
      message: "This coupon has reached its redemption limit.",
      doc_url: "https://docs.harmont.dev/api/errors/coupon-exhausted"
    )
  end

  defp send_coupon_error(conn, :coupon_already_claimed) do
    EndpointError.send_envelope(conn, 409,
      type: "conflict",
      code: "coupon_already_claimed",
      message: "This organization has already redeemed this coupon.",
      doc_url: "https://docs.harmont.dev/api/errors/coupon-already-claimed"
    )
  end

  defp parse_ts(nil, field),
    do: {:error, "The `#{field}` query parameter is required (ISO-8601)."}

  defp parse_ts("", field), do: {:error, "The `#{field}` query parameter is required (ISO-8601)."}

  defp parse_ts(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "The `#{field}` query parameter is not a valid ISO-8601 timestamp."}
    end
  end

  # The window is half-open `[from, to)`, so it must be strictly increasing. An
  # empty or inverted window (`to <= from`) is rejected at the edge rather than
  # handed to `Billing.usage/4`: it would scan to no purpose, and an inverted
  # window is almost certainly a caller bug we should surface, not silently
  # return an empty aggregate for.
  defp validate_window(from, to) do
    if DateTime.compare(to, from) == :gt do
      :ok
    else
      {:error, "The `to` timestamp must be strictly after `from` (the window is half-open)."}
    end
  end

  defp render_entry(entry) do
    %{
      id: entry.id,
      amount_cents: entry.amount_cents,
      source: entry.source,
      description: entry.description,
      created_at: entry.inserted_at
    }
  end
end
