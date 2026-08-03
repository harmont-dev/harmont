defmodule HarmontApi.AuthOAuthTest do
  @moduledoc """
  Integration tests for the Google + GitHub OAuth login endpoints.

  The real Assent caller is replaced by `HarmontApi.OAuthFake` (configured in
  `config/test.exs`), which returns canned identities keyed off the `code`
  param — so these tests drive the open-signup / provider-error / cap-reached
  branches end-to-end through the router and the Plan-2 contexts without any
  real HTTP.

  Signups are open: any identity-verified email proceeds to account creation,
  capped only by the platform signup cap.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts.User
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.SignupAttempt
  alias Harmont.Settings

  # Dispatch a JSON POST directly through the router. We build the conn with the
  # JSON already parsed into params (the `:api` pipeline has no Plug.Parsers, and
  # dispatching a bare router via Phoenix.ConnTest.post/3 doesn't parse the body),
  # which mirrors what Plug.Parsers would produce at the real endpoint.
  defp post_json(path, params) do
    :post
    |> Plug.Test.conn(path, Jason.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> HarmontApi.Router.call(HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /api/v0/auth/google" do
    test "allowed email -> 200 token + user; user/org + allowed attempt created" do
      conn =
        post_json("/api/v0/auth/google", %{
          "code" => "ok:alice@harmont.dev",
          "redirect_uri" => "https://app.harmont.dev/cb"
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert body["user"]["email"] == "alice@harmont.dev"

      user = Repo.get_by(User, email: "alice@harmont.dev")
      assert user
      assert Repo.get(Organization, user.personal_org_id)

      attempt = Repo.get_by(SignupAttempt, email: "alice@harmont.dev")
      assert attempt.decision == :allowed
      assert attempt.provider == :google
    end

    test "any identity-verified email signs up (no allowlist gate) -> 200 + user/org; logged :allowed" do
      conn =
        post_json("/api/v0/auth/google", %{
          "code" => "ok:anyone@example.com",
          "redirect_uri" => "https://app.harmont.dev/cb"
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert body["user"]["email"] == "anyone@example.com"

      user = Repo.get_by(User, email: "anyone@example.com")
      assert user
      assert Repo.get(Organization, user.personal_org_id)

      attempt = Repo.get_by(SignupAttempt, email: "anyone@example.com")
      assert attempt.decision == :allowed
      assert attempt.provider == :google
    end

    test "provider error -> error envelope" do
      conn =
        post_json("/api/v0/auth/google", %{
          "code" => "error",
          "redirect_uri" => "https://app.harmont.dev/cb"
        })

      assert conn.status >= 400
      body = decode(conn)
      assert body["error"]["code"] == "oauth_provider_error"
    end

    test "platform at capacity -> 503 signup_cap_reached; no user; logged :denied_cap_reached" do
      {:ok, _} = Settings.put_signup_cap(0, Repo)

      conn =
        post_json("/api/v0/auth/google", %{
          "code" => "ok:full@harmont.dev",
          "redirect_uri" => "https://app.harmont.dev/cb"
        })

      assert conn.status == 503
      assert decode(conn)["error"]["code"] == "signup_cap_reached"
      refute Repo.get_by(User, email: "full@harmont.dev")

      attempt = Repo.get_by(SignupAttempt, email: "full@harmont.dev")
      assert attempt.decision == :denied_cap_reached
      assert attempt.provider == :google
    end
  end

  describe "POST /api/v0/auth/github" do
    test "allowed email -> 200 token + user; allowed attempt recorded (github)" do
      conn =
        post_json("/api/v0/auth/github", %{
          "code" => "ok:bob@harmont.dev",
          "redirect_uri" => "https://app.harmont.dev/auth/callback"
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert body["user"]["email"] == "bob@harmont.dev"

      attempt = Repo.get_by(SignupAttempt, email: "bob@harmont.dev")
      assert attempt.decision == :allowed
      assert attempt.provider == :github
    end
  end
end
