defmodule Harmont.TokenTest do
  use ExUnit.Case, async: true

  alias Harmont.Token

  describe "generate/0" do
    test "returns a URL-safe base64 string without padding" do
      token = Token.generate()
      assert is_binary(token)
      # 32 bytes url_encode64 without padding = 43 chars
      assert byte_size(token) == 43
      # Only URL-safe base64 chars: A-Z a-z 0-9 - _
      assert token =~ ~r/\A[A-Za-z0-9\-_]+\z/
    end

    test "two successive calls return different values" do
      token1 = Token.generate()
      token2 = Token.generate()
      refute token1 == token2
    end
  end

  describe "hash/1" do
    test "returns a lowercase hex SHA-256 digest" do
      result = Token.hash("hello")
      assert is_binary(result)
      # SHA-256 = 32 bytes = 64 hex chars
      assert byte_size(result) == 64
      assert result =~ ~r/\A[0-9a-f]+\z/
    end

    test "is deterministic — same input, same output" do
      assert Token.hash("my-raw-secret") == Token.hash("my-raw-secret")
    end

    test "known vector: SHA-256 of empty string" do
      # echo -n "" | sha256sum => e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      assert Token.hash("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "different inputs produce different hashes" do
      refute Token.hash("abc") == Token.hash("xyz")
    end

    test "round-trip: hashing a generated token is deterministic" do
      raw = Token.generate()
      assert Token.hash(raw) == Token.hash(raw)
    end
  end
end
