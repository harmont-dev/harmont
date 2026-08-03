defmodule HarmontWeb.CorsTest do
  @moduledoc """
  The SPA at app.harmont.dev calls the API at api.harmont.dev cross-origin, so
  the endpoint must answer CORS preflights and stamp Access-Control-Allow-Origin
  on API responses. A missing CORS plug breaks browser login entirely; these
  tests guard against that regression.
  """
  use HarmontWeb.ConnCase, async: false

  # The allowed origin in the test env comes from config.exs's default.
  @allowed "https://app.harmont.dev"
  @foreign "https://evil.example.com"

  describe "preflight (OPTIONS)" do
    test "allowed origin gets a 2xx preflight with the CORS headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "authorization,content-type")
        |> dispatch(@endpoint, :options, "/api/v0/auth/google")

      assert conn.status in [200, 204]
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]

      allow_methods = get_resp_header(conn, "access-control-allow-methods") |> List.first() || ""
      assert allow_methods =~ "POST"

      allow_headers = get_resp_header(conn, "access-control-allow-headers") |> List.first() || ""
      assert allow_headers =~ "authorization"
    end

    test "foreign origin preflight gets no allow-origin header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @foreign)
        |> put_req_header("access-control-request-method", "POST")
        |> dispatch(@endpoint, :options, "/api/v0/auth/google")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "actual request" do
    test "allowed origin gets Access-Control-Allow-Origin on the response", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> dispatch(@endpoint, :get, "/api/v0/openapi.json")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
    end

    test "foreign origin gets no Access-Control-Allow-Origin header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @foreign)
        |> dispatch(@endpoint, :get, "/api/v0/openapi.json")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end
end
