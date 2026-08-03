defmodule HarmontApi.Stripe.Behaviour do
  @moduledoc """
  The behaviour isolating every `stripity_stripe` call behind a swappable
  boundary.

  The rest of the codebase (controllers, the webhook receiver) depends only on
  this behaviour — never on `stripity_stripe` directly. The implementation is
  chosen at call time by `HarmontApi.Stripe.impl/0`, which reads
  `config :harmont_api, :stripe_impl` (the real `HarmontApi.Stripe` in
  dev/prod, `HarmontApi.StripeFake` in test). This keeps the suite from ever
  hitting Stripe's network or signing machinery.
  """

  @typedoc """
  Inputs for a Checkout Session: the credit top-up amount in cents, the org
  the credit is for, the post-checkout redirect URLs, and arbitrary metadata
  (echoed back on the webhook event, e.g. the org id and session linkage).
  """
  @type checkout_params :: %{
          required(:amount_cents) => pos_integer(),
          required(:success_url) => String.t(),
          required(:cancel_url) => String.t(),
          optional(:org) => term(),
          optional(:customer) => String.t(),
          optional(:metadata) => map()
        }

  @typedoc "A created Checkout Session: its Stripe id and the hosted checkout URL."
  @type checkout_session :: %{id: String.t(), url: String.t()}

  @doc """
  Creates a Stripe Checkout Session for a one-off credit top-up.

  Returns `{:ok, %{id, url}}` on success; `{:error, term}` on any provider
  failure (network, auth, validation, missing config).
  """
  @callback create_checkout_session(checkout_params()) ::
              {:ok, checkout_session()} | {:error, term()}

  @typedoc """
  Inputs for creating a Stripe Customer: a display `name` and arbitrary
  `metadata` echoed onto the Stripe object (e.g. the Harmont org id).
  """
  @type customer_params :: %{
          required(:name) => String.t(),
          optional(:metadata) => map()
        }

  @typedoc "A created Customer: its Stripe id."
  @type customer :: %{id: String.t()}

  @doc """
  Creates a Stripe Customer for an organization.

  Returns `{:ok, %{id}}` on success; `{:error, term}` on any provider failure.
  Callers treat the error as non-fatal — checkout proceeds without a customer.
  """
  @callback create_customer(customer_params()) ::
              {:ok, customer()} | {:error, term()}

  @doc """
  Verifies a Stripe webhook's signature and parses its event.

  `raw_body` is the exact bytes Stripe signed (NOT a re-encoded parse),
  `sig_header` is the `Stripe-Signature` request header, and `secret` is the
  endpoint's signing secret. Returns `{:ok, event}` (a map with at least
  `"id"` and `"type"`) when the signature verifies; `{:error, term}` otherwise.
  """
  @callback construct_webhook_event(
              raw_body :: String.t(),
              sig_header :: String.t(),
              secret :: String.t()
            ) :: {:ok, map()} | {:error, term()}
end

defmodule HarmontApi.Stripe do
  @moduledoc """
  The real `HarmontApi.Stripe.Behaviour` implementation over `stripity_stripe`
  (v3).

  This module is the ONLY place in the codebase that names `stripity_stripe`
  modules (`Stripe.Checkout.Session`, `Stripe.Webhook`). Everything else
  depends on the behaviour and dispatches through `impl/0`, so swapping in the
  test fake (or, later, a different provider) needs no changes outside here.

  v3 API surface wrapped:

  - `Stripe.Checkout.Session.create/1` →
    `{:ok, %Stripe.Checkout.Session{id, url, ...}}` | `{:error, _}`.
  - `Stripe.Webhook.construct_event/3` →
    `{:ok, %Stripe.Event{} | map}` | `{:error, _}` (signature-verifying).

  The API key is read by `stripity_stripe` itself from
  `config :stripity_stripe, api_key: ...` (see `config/runtime.exs`).
  """

  @behaviour HarmontApi.Stripe.Behaviour

  alias Stripe.Checkout.Session, as: CheckoutSession
  alias Stripe.Customer

  @doc """
  Returns the configured Stripe implementation module.

  Reads `config :harmont_api, :stripe_impl`, defaulting to this real module.
  Tests set it to `HarmontApi.StripeFake`. Callers invoke
  `HarmontApi.Stripe.impl().create_checkout_session(...)` rather than naming
  an implementation directly.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:harmont_api, :stripe_impl, __MODULE__)

  @impl HarmontApi.Stripe.Behaviour
  def create_checkout_session(%{amount_cents: amount_cents} = params) do
    if configured?() do
      do_create_checkout_session(amount_cents, params)
    else
      {:error, :unconfigured}
    end
  end

  @impl HarmontApi.Stripe.Behaviour
  def create_customer(%{name: name} = params) do
    if configured?() do
      customer_params = %{name: name, metadata: stringify_keys(Map.get(params, :metadata, %{}))}

      case Customer.create(customer_params) do
        {:ok, %Customer{id: id}} -> {:ok, %{id: id}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unconfigured}
    end
  end

  defp do_create_checkout_session(amount_cents, params) do
    metadata = Map.get(params, :metadata, %{})

    session_params =
      %{
        mode: :payment,
        # Pin card-only so a session always settles synchronously
        # (`payment_status == "paid"` on `checkout.session.completed`). This
        # keeps the delayed-notification path latent: enabling an async method
        # via a dashboard toggle alone cannot mint credit before money settles,
        # because the webhook still gates crediting on a paid status.
        payment_method_types: ["card"],
        success_url: Map.fetch!(params, :success_url),
        cancel_url: Map.fetch!(params, :cancel_url),
        metadata: stringify_keys(metadata),
        line_items: [
          %{
            quantity: 1,
            price_data: %{
              currency: "usd",
              unit_amount: amount_cents,
              product_data: %{name: "Harmont credit top-up"}
            }
          }
        ]
      }
      |> maybe_put_customer(params)

    case CheckoutSession.create(session_params) do
      {:ok, %CheckoutSession{id: id, url: url}} -> {:ok, %{id: id, url: url}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Attach the org's persistent Stripe Customer to the session when the caller
  # resolved one. Absent → an anonymous session (back-compat / degraded path).
  defp maybe_put_customer(session_params, %{customer: customer}) when is_binary(customer),
    do: Map.put(session_params, :customer, customer)

  defp maybe_put_customer(session_params, _params), do: session_params

  @impl HarmontApi.Stripe.Behaviour
  def construct_webhook_event(_raw_body, _sig_header, secret) when secret in [nil, ""] do
    {:error, :unconfigured}
  end

  def construct_webhook_event(raw_body, sig_header, secret) do
    case Stripe.Webhook.construct_event(raw_body, sig_header, secret) do
      {:ok, %Stripe.Event{} = event} -> {:ok, expand_event(event)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Billing is configured only when stripity_stripe has a non-blank API key
  # (set from STRIPE_SECRET_KEY in config/runtime.exs). When absent, the
  # checkout path short-circuits to `{:error, :unconfigured}` rather than
  # handing a nil key to stripity_stripe.
  defp configured? do
    case Application.get_env(:stripity_stripe, :api_key) do
      nil -> false
      "" -> false
      key when is_binary(key) -> true
      _ -> false
    end
  end

  @doc false
  # Normalise a %Stripe.Event{} struct down to a plain map the rest of the
  # billing code reads with string keys (id/type/data/object), so the webhook
  # handler is agnostic to whether the event came from the struct path or the
  # fake. Public only so it can be unit-tested directly against a struct event.
  def expand_event(%Stripe.Event{} = event) do
    %{
      "id" => event.id,
      "type" => event.type,
      "data" => jsonify(event.data)
    }
  end

  # Recursively convert a Stripe resource — a struct, an atom-keyed map, or a
  # nested mix of both — into the plain STRING-keyed map shape that mirrors
  # Stripe's JSON wire format. Every billing consumer reads the event with
  # string keys (`object["id"]`, `object["payment_status"]`), so stringifying
  # the top level alone is not enough: `Map.from_struct/1` leaves ATOM keys on
  # the nested object, which made those reads silently return nil and crashed
  # the webhook on `get_by(session_id: nil)` (2026-06-11 incident).
  defp jsonify(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> jsonify()

  defp jsonify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonify(v)} end)

  defp jsonify(list) when is_list(list), do: Enum.map(list, &jsonify/1)
  defp jsonify(other), do: other

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
