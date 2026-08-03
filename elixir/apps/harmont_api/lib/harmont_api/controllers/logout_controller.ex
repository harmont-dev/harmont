defmodule HarmontApi.Controllers.LogoutController do
  @moduledoc """
  Session logout.

  `POST /api/v0/auth/logout` revokes the bearer token used to make the request
  by deleting its `ApiToken` row, so the same token immediately fails
  `validate_bearer` afterwards. Runs behind the bearer plug, so reaching this
  handler already proves the token is valid; we re-read the raw token from the
  `Authorization` header (the plug only assigns the user, not the raw token) and
  hand it to `Harmont.Accounts.revoke_token/2`. Always 204 — revoking is
  idempotent.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [get_req_header: 2, send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Repo

  tags(["auth"])

  operation(:logout,
    summary: "Log out (revoke the current bearer token)",
    description:
      "Revokes the bearer token used for this request. The token can no longer be " <>
        "used to authenticate. Idempotent.",
    operation_id: "logout",
    security: [%{"bearer" => []}],
    responses: [
      no_content: {"Token revoked", nil, nil}
    ]
  )

  @spec logout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout(conn, _params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> Accounts.revoke_token(token, Repo)
      _ -> :ok
    end

    send_resp(conn, 204, "")
  end
end
