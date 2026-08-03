defmodule Harmont.Token do
  @moduledoc """
  Secure token generation and hashing helpers.

  `generate/0` produces a cryptographically random URL-safe Base64 token
  (43 characters, no padding) suitable for use as an API token, magic-link
  token, or nonce.

  `hash/1` computes the lowercase-hex SHA-256 digest of a raw binary. All
  token hashes stored in the database MUST be produced by this function, so
  that lookup is a single deterministic hash comparison and raw secrets are
  never persisted.
  """

  @doc """
  Generates a 32-byte cryptographically random token, URL-safe Base64-encoded
  without padding (43 characters).
  """
  @spec generate() :: String.t()
  def generate do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns the lowercase-hex SHA-256 digest of `raw`.

  This is the canonical hash function for all token storage in Harmont.
  """
  @spec hash(binary()) :: String.t()
  def hash(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw)
    |> Base.encode16(case: :lower)
  end
end
