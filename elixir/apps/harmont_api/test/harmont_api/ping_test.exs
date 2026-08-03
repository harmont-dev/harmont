defmodule HarmontApi.PingTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias HarmontApi.Router

  @endpoint HarmontApi.Router

  defp call(method, path) do
    Phoenix.ConnTest.build_conn(method, path)
    |> Router.call(Router.init([]))
  end

  describe "GET /api/v0/ping" do
    test "returns 200 with status ok" do
      conn = call(:get, "/api/v0/ping")

      assert conn.status == 200
      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  describe "GET /api/v0/openapi.json" do
    test "returns a well-formed OpenAPI 3.x document" do
      conn = call(:get, "/api/v0/openapi.json")

      assert conn.status == 200
      body = json_response(conn, 200)

      assert %{"openapi" => "3.0." <> _, "info" => info, "paths" => paths} = body
      assert info["title"] == "Harmont API"
      assert info["version"] == "0"

      # The ping operation is present and carries its stable operation_id.
      assert get_in(paths, ["/api/v0/ping", "get", "operationId"]) == "ping"

      # The bearer security scheme is declared.
      assert get_in(body, ["components", "securitySchemes", "bearer", "scheme"]) == "bearer"
    end
  end
end
