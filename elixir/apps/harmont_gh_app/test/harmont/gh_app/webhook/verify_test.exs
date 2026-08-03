defmodule Harmont.GhApp.Webhook.VerifyTest do
  use ExUnit.Case, async: true
  alias Harmont.GhApp.Webhook.Verify

  @secret "it-is-a-very-long-secret"
  @body ~s({"zen":"Keep it logically awesome."})

  defp sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  test "accepts a correct signature" do
    assert Verify.valid?(@secret, @body, sign(@secret, @body))
  end

  test "rejects a tampered body" do
    refute Verify.valid?(@secret, @body <> "x", sign(@secret, @body))
  end

  test "rejects a missing or malformed header" do
    refute Verify.valid?(@secret, @body, nil)
    refute Verify.valid?(@secret, @body, "garbage")
    refute Verify.valid?(@secret, @body, "sha1=abcd")
  end
end
