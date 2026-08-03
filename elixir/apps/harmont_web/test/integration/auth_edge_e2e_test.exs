defmodule Harmont.Integration.AuthEdgeE2ETest do
  @moduledoc """
  End-to-end auth integration test through the REAL composed endpoint.

  This drives a full authentication flow against `HarmontWeb.Endpoint` — the
  single endpoint that mounts `HarmontApi.Router` at `/api/v0` — using
  `Phoenix.ConnTest` (no live listener needed). It proves the router mount, the
  `:api`/`:authed` plug pipelines (JSON parsing, the bearer `Auth` plug), and
  the Plan-2 contexts all work together as one composed system:

    1. `POST /api/v0/auth/google` with a stubbed OAuth provider
       → 200 + a session bearer token.
    2. `GET /api/v0/user` with the bearer → 200 (the authed pipeline accepts it).
    3. `POST /api/v0/auth/logout` with the bearer → 204 (token revoked).
    4. `GET /api/v0/user` with the now-revoked bearer → 401 envelope.

  The OAuth provider call is stubbed via `:oauth_impl` so no real HTTP happens;
  everything else is the real edge + contexts + DB.
  """
  use HarmontWeb.ConnCase, async: false

  setup do
    # Swap in the web-app's OAuth fake for the duration of this test, restoring
    # whatever was configured (harmont_api's fake) afterwards.
    previous = Application.get_env(:harmont_api, :oauth_impl)
    Application.put_env(:harmont_api, :oauth_impl, HarmontWeb.Support.OAuthFake)
    on_exit(fn -> Application.put_env(:harmont_api, :oauth_impl, previous) end)
    :ok
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  test "OAuth login -> /user 200 -> logout -> /user 401, through HarmontWeb.Endpoint", %{
    conn: conn
  } do
    # 1. OAuth login -> bearer token.
    login_conn =
      post_json(conn, "/api/v0/auth/google", %{
        "code" => "ok:e2e@harmont.dev",
        "redirect_uri" => "https://app.harmont.dev/cb"
      })

    assert login_conn.status == 200
    body = json_response(login_conn, 200)
    token = body["token"]
    assert is_binary(token) and token != ""
    assert body["user"]["email"] == "e2e@harmont.dev"

    bearer = "Bearer " <> token

    # 2. Authed GET /user with the bearer -> 200.
    user_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> get("/api/v0/user")

    assert user_conn.status == 200
    user_body = json_response(user_conn, 200)
    assert user_body["email"] == "e2e@harmont.dev"

    # 3. Logout -> 204, revoking the token.
    logout_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> post("/api/v0/auth/logout")

    assert logout_conn.status == 204

    # 4. The same bearer is now rejected -> 401 envelope.
    revoked_conn =
      build_conn()
      |> put_req_header("authorization", bearer)
      |> get("/api/v0/user")

    assert revoked_conn.status == 401
    error_body = json_response(revoked_conn, 401)
    assert is_binary(error_body["error"]["code"])
  end
end
