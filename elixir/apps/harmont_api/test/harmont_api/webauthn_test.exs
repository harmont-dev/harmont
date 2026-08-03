defmodule HarmontApi.WebauthnTest do
  @moduledoc """
  Covers the WebAuthn payload-shape handling in `HarmontApi.Webauthn`.

  The crypto itself is exercised by Wax's own FIDO2 conformance suite and faked
  in controller tests (`HarmontApi.WebauthnFake`). What is NOT covered there is
  how we *locate* the attestation/assertion buffers in the JSON the browser
  sends — and that was a real production bug: `navigator.credentials.create/get`
  (and SimpleWebAuthn) emit the W3C `RegistrationResponseJSON` /
  `AuthenticationResponseJSON` shape, where `attestationObject`,
  `clientDataJSON`, `authenticatorData`, `signature`, and `transports` are
  nested under a `response` object — but the server read them at the top level,
  so every passkey register/login failed with `missing_field` before any crypto
  ran. These tests pin the nesting (with a flat-shape fallback) in place.
  """
  use ExUnit.Case, async: true

  alias HarmontApi.Webauthn

  # base64url(no padding) of the bytes "hello" / "world".
  @hello Base.url_encode64("hello", padding: false)
  @world Base.url_encode64("world", padding: false)

  describe "WebAuthn field extraction (W3C `response` nesting)" do
    test "reads a buffer nested under `response` (the shape browsers actually send)" do
      payload = %{
        "id" => "cred",
        "rawId" => "cred",
        "type" => "public-key",
        "response" => %{"attestationObject" => @hello, "clientDataJSON" => @world}
      }

      assert {:ok, "hello"} = Webauthn.decode_payload_field(payload, "attestationObject")
      assert {:ok, "world"} = Webauthn.decode_payload_field(payload, "clientDataJSON")
    end

    test "falls back to a top-level (flattened) field" do
      assert {:ok, "hello"} =
               Webauthn.decode_payload_field(%{"signature" => @hello}, "signature")
    end

    test "prefers the nested value when both are present" do
      payload = %{"attestationObject" => @world, "response" => %{"attestationObject" => @hello}}
      assert {:ok, "hello"} = Webauthn.decode_payload_field(payload, "attestationObject")
    end

    test "missing in both locations -> a missing_field reason (not a crash)" do
      assert {:error, {:missing_field, "authenticatorData"}} =
               Webauthn.decode_payload_field(%{"response" => %{}}, "authenticatorData")

      assert {:error, {:missing_field, "authenticatorData"}} =
               Webauthn.decode_payload_field(%{}, "authenticatorData")
    end

    test "a present-but-undecodable buffer -> an invalid_base64 reason" do
      assert {:error, {:invalid_base64, "attestationObject"}} =
               Webauthn.decode_payload_field(
                 %{"response" => %{"attestationObject" => "not base64!!"}},
                 "attestationObject"
               )
    end
  end
end
