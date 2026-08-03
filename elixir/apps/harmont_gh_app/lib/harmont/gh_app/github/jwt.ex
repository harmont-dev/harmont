defmodule Harmont.GhApp.GitHub.Jwt do
  @moduledoc """
  Mint the short-lived App JWT GitHub requires to exchange for installation
  access tokens.

  Spec:
  - Algorithm: RS256
  - `iss`: the GitHub App ID as a string (GitHub requires a string)
  - `iat`: `unix(now) - 60` — backdated 60 s to absorb clock skew
  - `exp`: `unix(now) + 540` — 9 minutes; inside GitHub's 10-minute cap
  - Epoch seconds are integers (GitHub rejects scientific notation)

  Pure module — no DB, no network, no process state.
  """

  @doc """
  Mint a compact-serialized RS256 JWT signed with the App's RSA private key PEM.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec mint(String.t(), integer(), DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def mint(private_key_pem, app_id, %DateTime{} = now) do
    unix = DateTime.to_unix(now)

    claims = %{
      "iss" => Integer.to_string(app_id),
      "iat" => unix - 60,
      "exp" => unix + 540
    }

    # A malformed/empty PEM makes the underlying jose signer raise an
    # ArgumentError rather than returning an error tuple. Honor this function's
    # `{:ok, _} | {:error, _}` contract so callers (e.g. the best-effort
    # installation reconcile during connect) can fall through gracefully instead
    # of crashing the request.
    try do
      signer = Joken.Signer.create("RS256", %{"pem" => private_key_pem})

      claims
      |> Joken.encode_and_sign(signer)
      |> normalize()
    rescue
      e -> {:error, e}
    end
  end

  @doc "Peek at the claims of a JWT without verifying the signature. Delegates to `Joken.peek_claims/1`."
  @spec peek_claims(String.t()) :: {:ok, map()} | {:error, term()}
  def peek_claims(token), do: Joken.peek_claims(token)

  # encode_and_sign returns {:ok, token, claims} on success; strip the claims.
  defp normalize({:ok, token, _claims}), do: {:ok, token}
  defp normalize({:error, reason}), do: {:error, reason}
end
