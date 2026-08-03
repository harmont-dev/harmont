defmodule Harmont.Bitbucket.Webhook.VerifyTest do
  use ExUnit.Case, async: true
  alias Harmont.Bitbucket.Webhook.Verify

  @secret String.duplicate("x", 20)

  defp sign(raw), do: "sha256=" <> (:crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower))

  test "accepts a correct sha256 signature" do
    raw = ~s({"x":1})
    assert Verify.valid?(@secret, raw, sign(raw))
  end

  test "rejects a wrong signature" do
    refute Verify.valid?(@secret, ~s({"x":1}), "sha256=deadbeef")
  end

  test "rejects a missing/nil signature" do
    refute Verify.valid?(@secret, ~s({"x":1}), nil)
  end
end
