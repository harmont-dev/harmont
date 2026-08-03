defmodule HarmontWeb.OpsRouter do
  @moduledoc """
  Minimal browser/LiveView router for internal ops surfaces.

  Today it hosts only the Oban Web dashboard at `/ops/oban`. It is mounted into
  the endpoint's manual plug chain BEFORE the `HarmontApi.Router` catch-all, so
  `/ops/*` is served here and every other path falls through to the JSON API
  unchanged. Every route in this router sits behind
  `HarmontWeb.Plugs.ObanDashboardAuth` (HTTP Basic) — there is no unauthenticated
  ops surface.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Oban.Web.Router

  pipeline :ops_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(HarmontWeb.Plugs.ObanDashboardAuth)
  end

  scope "/ops" do
    pipe_through(:ops_browser)

    # Drives the default `Oban` instance (running in harmont_core).
    oban_dashboard("/oban")
  end
end
