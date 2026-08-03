defmodule Harmont.LogToken do
  @moduledoc """
  Compact, build-scoped HMAC log token shared by the Harmont API edge (which
  mints it) and the `harmont_web` SSE log stream (which verifies it).

  Format: `base64url(payload_json) <> "." <> base64url(hmac_sha256(secret, base64url(payload_json)))`

  `payload_json` is `{"build": "<external_build_uuid>", "exp": <unix_seconds>}`.

  This is NOT a `Phoenix.Token` — a plain shared-secret HMAC that both the API
  and the web edge control, giving full transparency over the format without
  replicating Plug.Crypto's binary envelope. Both edges call `secret/0` to read
  the SAME shared key from `config :harmont_web, HarmontWeb.Endpoint`
  (`HARMONT_LOG_TOKEN_SECRET` in prod), so they agree on key and format without
  duplicating the scheme.

  All functions take the secret explicitly so the core module stays pure;
  `secret/0` is the convenience resolver the edges share.
  """

  @doc """
  Mints a build-scoped token that `verify/2` accepts.

  `build_uuid` is the build's `external_build_id`; `exp` is the absolute expiry
  in unix seconds.
  """
  @spec sign(String.t(), integer(), String.t()) :: String.t()
  def sign(build_uuid, exp, secret)
      when is_binary(build_uuid) and is_integer(exp) and is_binary(secret) do
    payload =
      Base.url_encode64(Jason.encode!(%{"build" => build_uuid, "exp" => exp}), padding: false)

    sig = Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, payload), padding: false)
    payload <> "." <> sig
  end

  @doc """
  Verifies `token` against `secret`.

  Returns `{:ok, build_uuid}` for a well-formed, correctly-signed, unexpired
  token, or `{:error, :malformed | :bad_signature | :expired}`.
  """
  @spec verify(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :malformed | :bad_signature | :expired}
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    with [p, sig] <- String.split(token, ".", parts: 2),
         expected <- Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, p), padding: false),
         true <- constant_time_eq?(sig, expected),
         {:ok, json} <- Base.url_decode64(p, padding: false),
         {:ok, %{"build" => build, "exp" => exp}} <- Jason.decode(json) do
      cond do
        not is_integer(exp) -> {:error, :malformed}
        exp > System.system_time(:second) -> {:ok, build}
        true -> {:error, :expired}
      end
    else
      false -> {:error, :bad_signature}
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Returns the shared HMAC secret.

  Reads `config :harmont_web, HarmontWeb.Endpoint, log_token_secret:`; falls
  back to `"dev-log-token-secret"` when unconfigured. Both the API and the web
  edge call this so they share the same key.
  """
  @spec secret() :: String.t()
  def secret do
    Application.get_env(:harmont_web, HarmontWeb.Endpoint)[:log_token_secret] ||
      "dev-log-token-secret"
  end

  # :crypto.hash_equals/2 requires equal-length binaries; guard the length first
  # to avoid a badarg crash while still preserving constant-time behaviour for
  # same-length inputs.
  defp constant_time_eq?(a, b) when byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp constant_time_eq?(_, _), do: false
end
