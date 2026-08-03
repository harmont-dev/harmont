defmodule HarmontApi.Controllers.PingController do
  @moduledoc """
  Liveness/identity probe for the public API surface.

  `GET /api/v0/ping` returns `{"status": "ok"}` and exists so clients (CLI,
  frontend, uptime checks) can confirm they are talking to a live Harmont API
  without authenticating.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema

  tags(["meta"])

  operation(:ping,
    summary: "Liveness probe",
    description: "Returns `{\"status\": \"ok\"}` if the API is up. No auth required.",
    operation_id: "ping",
    "x-internal": true,
    responses: [
      ok:
        {"Service is up", "application/json",
         %Schema{
           type: :object,
           properties: %{status: %Schema{type: :string, example: "ok"}},
           required: [:status]
         }}
    ]
  )

  @spec ping(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ping(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
