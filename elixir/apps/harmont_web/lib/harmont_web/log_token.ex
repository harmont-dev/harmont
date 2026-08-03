defmodule HarmontWeb.LogToken do
  @moduledoc """
  Build-scoped HMAC log token for the SSE log stream.

  Thin delegate over `Harmont.LogToken` (in `harmont_core`), which is the single
  shared implementation the Harmont API edge mints with and this edge verifies.
  Keeping the scheme in core lets both edges share it without a dependency
  cycle (web depends on api, so the shared code cannot live in either edge).

  See `Harmont.LogToken` for the exact format.
  """

  alias Harmont.LogToken

  @doc "Verifies a token. See `Harmont.LogToken.verify/2`."
  @spec verify(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :malformed | :bad_signature | :expired}
  defdelegate verify(token, secret), to: LogToken

  @doc "Mints a token. See `Harmont.LogToken.sign/3`."
  @spec sign(String.t(), integer(), String.t()) :: String.t()
  defdelegate sign(build_uuid, exp, secret), to: LogToken

  @doc "Returns the shared HMAC secret. See `Harmont.LogToken.secret/0`."
  @spec secret() :: String.t()
  defdelegate secret(), to: LogToken
end
