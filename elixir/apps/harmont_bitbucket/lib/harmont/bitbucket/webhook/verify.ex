defmodule Harmont.Bitbucket.Webhook.Verify do
  @moduledoc """
  Verifies Bitbucket's `X-Hub-Signature` over the raw request body. Bitbucket uses
  the WebSub convention `method=hexdigest` (currently `sha256=...`), HMAC keyed by
  the (app-wide) webhook secret. Constant-time compare; a missing signature is a
  hard reject (signing is opt-in per webhook, so a secretless delivery must not be
  trusted).
  """

  @spec valid?(String.t(), binary(), String.t() | nil) :: boolean()
  def valid?(_secret, _raw, nil), do: false

  def valid?(secret, raw, "sha256=" <> hex) do
    expected = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(String.downcase(hex), expected)
  end

  def valid?(_secret, _raw, _other), do: false
end
