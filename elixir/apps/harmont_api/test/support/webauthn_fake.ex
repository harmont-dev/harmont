defmodule HarmontApi.WebauthnFake do
  @moduledoc """
  Test fake for the `HarmontApi.Webauthn` verification boundary.

  Wired in via `config :harmont_api, :webauthn_impl, HarmontApi.WebauthnFake`
  (test env). It stands in for the Wax crypto only — the challenge store/consume,
  user creation, sign-counter policy, and session minting are all exercised for
  real against Postgres; only the attestation/assertion signature check is faked
  (a real signing authenticator isn't available in CI, and Wax has its own
  FIDO2 conformance suite for the crypto).

  Behaviour is keyed off a marker the test plants in the response payload so a
  single test can drive both the success and failure branches deterministically:

  - `verify_registration/2` — returns a canned credential. The caller may pass
    `"_fake" => "ok"` (default) for success or `"_fake" => "error"` to get a
    `passkey_registration_failed` catalog error. The credential id is derived
    from the response's `"_cred_id"` (Base64url) if present, else a fixed default.
  - `verify_authentication/3` — returns `{:ok, asserted_count}` where
    `asserted_count` comes from `"_sign_count"` (default 1), or a
    `passkey_assertion_failed` error when `"_fake" => "error"`.
  """

  @behaviour HarmontApi.Webauthn.Behaviour

  alias Harmont.Error

  @default_cred_id <<0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02, 0x03, 0x04>>

  @impl true
  def verify_registration(%{"_fake" => "error"}, _challenge),
    do: {:error, Error.new(:passkey_registration_failed)}

  def verify_registration(response, _challenge) do
    {:ok,
     %{
       credential_id: cred_id(response),
       # A plausible ES256 COSE key map; serialized like the real impl does.
       public_key: HarmontApi.Webauthn.cose_key_to_binary(canned_cose_key()),
       sign_count: 0,
       aaguid: "00000000000000000000000000000000",
       transports: "internal,hybrid"
     }}
  end

  @impl true
  def verify_authentication(%{"_fake" => "error"}, _challenge, _stored_cred),
    do: {:error, Error.new(:passkey_assertion_failed)}

  def verify_authentication(response, _challenge, _stored_cred) do
    {:ok, Map.get(response, "_sign_count", 1)}
  end

  defp cred_id(%{"_cred_id" => b64}) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> bin
      :error -> @default_cred_id
    end
  end

  defp cred_id(_), do: @default_cred_id

  defp canned_cose_key do
    %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => :crypto.strong_rand_bytes(32),
      -3 => :crypto.strong_rand_bytes(32)
    }
  end
end
