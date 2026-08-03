defmodule HarmontApi.Controllers.AuthGithubController do
  @moduledoc """
  GitHub OAuth login endpoint.

  `POST /api/v0/auth/github` accepts the authorization `code` from the SPA's
  OAuth redirect, exchanges it for the GitHub user (including the primary
  verified email via the `user:email` scope), upserts the user + personal org
  (capped by the platform signup cap), and returns a session bearer token.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias HarmontApi.Controllers.OAuthLogin
  alias HarmontApi.Schemas.AuthGithubRequest
  alias HarmontApi.Schemas.AuthTokenResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  tags(["auth"])

  operation(:create,
    summary: "Sign in with GitHub",
    description:
      "Exchanges a GitHub authorization code for a Harmont session token, " <>
        "creating the user and their personal org on first sign-in.",
    operation_id: "authGithub",
    "x-internal": true,
    request_body: {"GitHub OAuth callback", "application/json", AuthGithubRequest},
    responses: [
      ok: {"Session token + user", "application/json", AuthTokenResponse},
      bad_gateway: {"GitHub rejected the code", "application/json", ErrorSchema},
      service_unavailable: {"Platform at capacity", "application/json", ErrorSchema},
      internal_server_error: {"Sign-up failed", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    OAuthLogin.login(conn, :github, %{
      code: params["code"],
      redirect_uri: params["redirect_uri"]
    })
  end
end
