defmodule Harmont.GhApp.Webhook.Verify do
  @moduledoc "Constant-time HMAC-SHA256 verification of GitHub's X-Hub-Signature-256."

  @doc """
  True iff `sig_header` ("sha256=<hex>") is the HMAC-SHA256 of `body` under `secret`.

  Uses `Plug.Crypto.secure_compare/2` for constant-time comparison to prevent
  timing attacks. Rejects nil, non-binary, wrong-algorithm, and malformed-hex headers.
  """
  def valid?(secret, body, sig_header) when is_binary(sig_header) do
    case sig_header do
      "sha256=" <> hex ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, provided} ->
            computed = :crypto.mac(:hmac, :sha256, secret, body)
            Plug.Crypto.secure_compare(computed, provided)

          :error ->
            false
        end

      _ ->
        false
    end
  end

  def valid?(_secret, _body, _sig), do: false
end
