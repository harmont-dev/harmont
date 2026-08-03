defmodule HarmontApi.Controllers.LogTokenController do
  @moduledoc """
  Mints a build-scoped HMAC log token for the SSE log stream.

  `GET …/builds/:number/log-token` returns `%{token, expires_at}`. The token is
  minted over the build's `external_build_id` with a ~1 hour TTL using
  `Harmont.LogToken` — the single shared implementation the `harmont_web` SSE
  log stream validates with (via `HarmontWeb.LogToken`). API and web read the
  same secret from `Harmont.LogToken.secret/0`, so the minted token is accepted
  by the stream's validator without any duplicated scheme.

  The build is supplied by `HarmontApi.Plugs.BuildScope` (`conn.assigns.build`).
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.LogToken
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.LogTokenResponse

  tags(["builds"])

  # One hour, matching the log stream's expectation of a short-lived token.
  @ttl_seconds 3600

  operation(:show,
    summary: "Mint a build-scoped log token",
    description:
      "Returns a short-lived (~1 hour) HMAC token the SSE log stream accepts, " <>
        "scoped to this build. Pass it as the stream's `token` query parameter.",
    operation_id: "getBuildLogToken",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
      number: [in: :path, type: :integer, required: true, description: "The build number."]
    ],
    responses: [
      ok: {"The log token and its expiry", "application/json", LogTokenResponse},
      not_found: {"No such build in this pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    exp = System.system_time(:second) + @ttl_seconds
    build = conn.assigns.build
    token = LogToken.sign(build.external_build_id, exp, LogToken.secret())

    json(conn, %{
      token: token,
      expires_at: DateTime.from_unix!(exp)
    })
  end
end
