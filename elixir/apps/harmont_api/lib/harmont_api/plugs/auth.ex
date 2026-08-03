defmodule HarmontApi.Plugs.Auth do
  @moduledoc """
  Bearer-token authentication plug.

  Reads `Authorization: Bearer <token>`, validates it via
  `Harmont.Accounts.validate_bearer/2`, and on success assigns the owning user
  to `conn.assigns.current_user`. On a missing header, a malformed header, or
  an invalid/expired token, it halts with `401 Unauthorized` and the Harmont
  error envelope (`HarmontApi.EndpointError`).

  Use it in a router pipeline for any bearer-authed scope:

      pipeline :authed do
        plug HarmontApi.Plugs.Auth
      end
  """

  import Plug.Conn

  alias Harmont.Accounts
  alias HarmontApi.EndpointError

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case bearer_token(conn) do
      {:ok, token} -> authenticate(conn, token)
      :error -> EndpointError.send_unauthorized(conn)
    end
  end

  defp authenticate(conn, token) do
    case Accounts.validate_bearer(token, DateTime.utc_now()) do
      {:ok, user} -> assign(conn, :current_user, user)
      {:error, :invalid} -> EndpointError.send_unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> :error
    end
  end
end
