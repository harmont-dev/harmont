defmodule HarmontApi.StripeFake do
  @moduledoc """
  In-process `HarmontApi.Stripe.Behaviour` fake for the test suite.

  Wired in via `config :harmont_api, :stripe_impl, HarmontApi.StripeFake`
  (config/test.exs) so the suite never touches Stripe's network or signature
  machinery. The checkout call returns a canned session; the webhook call
  decodes the raw body as the event (so tests synthesise events directly as
  JSON without real Stripe signing). A magic `sig_header` of `"bad"` lets a
  test exercise the signature-failure branch.

  ## Driving the checkout error branches

  By default `create_checkout_session/1` returns a canned `{:ok, %{id, url}}`.
  A test can force the failure branches by setting
  `config :harmont_api, :stripe_fake_checkout` (best via `put_env`/`on_exit`):

  - `:unconfigured` → `{:error, :unconfigured}` (drives the 503 path)
  - `:provider`     → `{:error, :provider}` (drives the 502 path)
  - anything else / unset → the canned success

  `create_customer/1` works analogously via
  `config :harmont_api, :stripe_fake_customer` (`:unconfigured`/`:provider` →
  the matching error, anything else / unset → a canned `{:ok, %{id}}`).

  ## Inspecting what checkout received

  `create_checkout_session/1` stashes the params it was handed in the calling
  process's dictionary under `:stripe_fake_last_checkout`. Because the test
  suite drives the controller synchronously in the test process, a test can
  read it back (`Process.get(:stripe_fake_last_checkout)`) to assert that, e.g.,
  the resolved `:customer` id was threaded into the session.
  """

  @behaviour HarmontApi.Stripe.Behaviour

  @impl HarmontApi.Stripe.Behaviour
  def create_checkout_session(params) do
    Process.put(:stripe_fake_last_checkout, params)

    case Application.get_env(:harmont_api, :stripe_fake_checkout, :ok) do
      :unconfigured ->
        {:error, :unconfigured}

      :provider ->
        {:error, :provider}

      _ ->
        id = "cs_test_#{System.unique_integer([:positive])}"
        {:ok, %{id: id, url: "https://checkout.stripe/#{id}"}}
    end
  end

  @impl HarmontApi.Stripe.Behaviour
  def create_customer(_params) do
    case Application.get_env(:harmont_api, :stripe_fake_customer, :ok) do
      :unconfigured -> {:error, :unconfigured}
      :provider -> {:error, :provider}
      _ -> {:ok, %{id: "cus_test_#{System.unique_integer([:positive])}"}}
    end
  end

  @impl HarmontApi.Stripe.Behaviour
  def construct_webhook_event(_raw_body, "bad", _secret), do: {:error, :invalid_signature}

  def construct_webhook_event(raw_body, _sig_header, _secret) do
    case Jason.decode(raw_body) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _ -> {:error, :invalid_payload}
    end
  end
end
