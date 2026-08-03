defmodule HarmontWeb.LogTokenTest do
  use ExUnit.Case, async: true
  alias HarmontWeb.LogToken

  @secret "test-shared-secret"

  # mint the compact token format: b64url(payload) <> "." <> b64url(hmac)
  defp mint(build, exp) do
    payload = Jason.encode!(%{"build" => build, "exp" => exp})
    p = Base.url_encode64(payload, padding: false)
    mac = :crypto.mac(:hmac, :sha256, @secret, p) |> Base.url_encode64(padding: false)
    p <> "." <> mac
  end

  test "verify/2 accepts a well-formed unexpired token and returns the build uuid" do
    tok = mint("build-123", System.system_time(:second) + 3600)
    assert {:ok, "build-123"} = LogToken.verify(tok, @secret)
  end

  test "verify/2 rejects a tampered signature" do
    tok = mint("build-123", System.system_time(:second) + 3600)
    assert {:error, :bad_signature} = LogToken.verify(tok <> "x", @secret)
  end

  test "verify/2 rejects an expired token" do
    tok = mint("build-123", System.system_time(:second) - 1)
    assert {:error, :expired} = LogToken.verify(tok, @secret)
  end

  test "verify/2 rejects malformed input" do
    assert {:error, :malformed} = LogToken.verify("nonsense", @secret)
  end

  test "verify/2 returns :malformed (not :expired) when exp is a float" do
    # A JSON float exp must not be silently misclassified as :expired.
    payload = Jason.encode!(%{"build" => "build-123", "exp" => 1.5})
    p = Base.url_encode64(payload, padding: false)
    mac = :crypto.mac(:hmac, :sha256, @secret, p) |> Base.url_encode64(padding: false)
    tok = p <> "." <> mac
    assert {:error, :malformed} = LogToken.verify(tok, @secret)
  end

  # Cross-implementation regression vector.
  # A pre-minted golden token for secret "xsecretx", build "build-abc", exp 4102444800.
  # Payload (decoded): {"build":"build-abc","exp":4102444800}
  # Pins the format contract: base64url-unpadded encoding, HMAC-SHA256 over the
  # base64url payload string, and JSON key order. If this test ever fails, the
  # token format has drifted — do NOT paper over it; fix the format contract.
  test "verify/2 accepts a pre-minted golden token (cross-impl compatibility vector)" do
    golden_token =
      "eyJidWlsZCI6ImJ1aWxkLWFiYyIsImV4cCI6NDEwMjQ0NDgwMH0.PvK2NJ2pu0YlN4MzukkSxlqXiSABWrJsAbF6WSgyXPo"

    assert {:ok, "build-abc"} = LogToken.verify(golden_token, "xsecretx")
  end
end
