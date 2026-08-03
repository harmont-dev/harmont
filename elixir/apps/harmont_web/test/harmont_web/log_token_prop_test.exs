defmodule HarmontWeb.LogTokenPropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias HarmontWeb.LogToken
  import StreamData

  # Mint the compact `base64url(payload).base64url(hmac)` format the verifier expects.
  defp mint(secret, build, exp) do
    p = %{"build" => build, "exp" => exp} |> Jason.encode!() |> Base.url_encode64(padding: false)
    mac = :crypto.mac(:hmac, :sha256, secret, p) |> Base.url_encode64(padding: false)
    p <> "." <> mac
  end

  property "verify accepts a freshly minted, unexpired token and returns the build" do
    future = System.system_time(:second) + 3600

    check all(
            secret <- string(:alphanumeric, min_length: 8),
            build <- string(:alphanumeric, min_length: 1, max_length: 40)
          ) do
      assert {:ok, ^build} = LogToken.verify(mint(secret, build, future), secret)
    end
  end

  property "appending to the signature is rejected" do
    future = System.system_time(:second) + 3600

    check all(
            secret <- string(:alphanumeric, min_length: 8),
            build <- string(:alphanumeric, min_length: 1)
          ) do
      tok = mint(secret, build, future)
      assert {:error, _} = LogToken.verify(tok <> "x", secret)
    end
  end

  property "a wrong secret is rejected with :bad_signature" do
    future = System.system_time(:second) + 3600

    check all(
            s1 <- string(:alphanumeric, min_length: 8),
            s2 <- string(:alphanumeric, min_length: 8),
            s1 != s2,
            build <- string(:alphanumeric, min_length: 1)
          ) do
      assert {:error, :bad_signature} = LogToken.verify(mint(s1, build, future), s2)
    end
  end

  property "an expired token is rejected with :expired" do
    past = System.system_time(:second) - 3600

    check all(
            secret <- string(:alphanumeric, min_length: 8),
            build <- string(:alphanumeric, min_length: 1)
          ) do
      assert {:error, :expired} = LogToken.verify(mint(secret, build, past), secret)
    end
  end
end
