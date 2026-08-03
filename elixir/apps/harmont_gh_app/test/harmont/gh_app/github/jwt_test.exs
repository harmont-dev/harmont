defmodule Harmont.GhApp.GitHub.JwtTest do
  use ExUnit.Case, async: true
  alias Harmont.GhApp.GitHub.Jwt
  alias Harmont.TestSupport.Rsa

  setup do
    # 2048-bit test key — see test/support/rsa.ex
    {:ok, pem: Rsa.private_pem()}
  end

  test "mint produces an RS256 JWT with the right iss/iat/exp window", %{pem: pem} do
    now = ~U[2026-05-30 12:00:00Z]
    {:ok, token} = Jwt.mint(pem, 42, now)
    {:ok, claims} = Jwt.peek_claims(token)
    assert claims["iss"] == "42"
    assert claims["iat"] == DateTime.to_unix(now) - 60
    assert claims["exp"] == DateTime.to_unix(now) + 540
  end

  test "mint encodes integer epoch seconds (no floats or scientific notation)", %{pem: pem} do
    now = ~U[2026-05-30 12:00:00Z]
    {:ok, token} = Jwt.mint(pem, 99, now)
    {:ok, claims} = Jwt.peek_claims(token)
    assert is_integer(claims["iat"])
    assert is_integer(claims["exp"])
  end

  test "peek_claims delegates to Joken and returns {:ok, claims}", %{pem: pem} do
    now = ~U[2026-05-30 12:00:00Z]
    {:ok, token} = Jwt.mint(pem, 7, now)
    assert {:ok, %{"iss" => "7"}} = Jwt.peek_claims(token)
  end
end
