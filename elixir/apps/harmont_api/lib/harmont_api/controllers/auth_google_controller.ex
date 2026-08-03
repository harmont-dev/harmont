defmodule HarmontApi.Controllers.AuthGoogleController do
  @moduledoc """
  Google OAuth login endpoint.

  `POST /api/v0/auth/google` accepts the authorization `code` (and the
  `redirect_uri` the SPA used) from the SPA's OAuth redirect, exchanges it for
  the Google user, upserts the user + personal org (capped by the platform
  signup cap), and returns a session bearer token.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias HarmontApi.Controllers.OAuthLogin
  alias HarmontApi.Schemas.AuthGoogleRequest
  alias HarmontApi.Schemas.AuthTokenResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  tags(["auth"])

  operation(:create,
    summary: "Sign in with Google",
    description:
      "Exchanges a Google authorization code for a Harmont session token, " <>
        "creating the user and their personal org on first sign-in.",
    operation_id: "authGoogle",
    "x-internal": true,
    request_body: {"Google OAuth callback", "application/json", AuthGoogleRequest},
    responses: [
      ok: {"Session token + user", "application/json", AuthTokenResponse},
      bad_gateway: {"Google rejected the code", "application/json", ErrorSchema},
      service_unavailable: {"Platform at capacity", "application/json", ErrorSchema},
      internal_server_error: {"Sign-up failed", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    OAuthLogin.login(conn, :google, %{
      code: params["code"],
      redirect_uri: params["redirect_uri"]
    })
  end
end
