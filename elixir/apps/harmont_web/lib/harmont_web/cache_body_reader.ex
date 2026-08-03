defmodule HarmontWeb.CacheBodyReader do
  @moduledoc """
  Stash the raw request body for the webhook paths so signature verification
  sees the exact bytes the sender signed.

  `Plug.Parsers` consumes (and re-encodes) the body, but a webhook HMAC/HMAC-SHA
  signature is computed over the literal wire bytes — any re-encoding (key
  ordering, whitespace) would break verification. We therefore cache the raw
  chunks under `conn.assigns.raw_body` (newest-first; the caller reverses before
  joining).

  Scoped to the webhook paths only:

  - `/webhooks/...` — any provider webhook (GitHub `X-Hub-Signature-256` HMAC,
    and future providers under `/webhooks/:provider`).
  - `/api/v0/stripe/webhook` — Stripe `Stripe-Signature` verification.

  Every other path (agent upgrade, log stream, large multipart) flows through
  `Plug.Conn.read_body/2` unchanged so we never buffer big payloads.
  """

  def read_body(%Plug.Conn{request_path: "/webhooks/" <> _} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
    end
  end

  def read_body(%Plug.Conn{request_path: "/api/v0/stripe/webhook"} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp cache(conn, body), do: update_in(conn.assigns[:raw_body], &[body | &1 || []])
end
