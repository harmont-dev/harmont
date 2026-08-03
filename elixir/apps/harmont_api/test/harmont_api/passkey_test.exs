defmodule HarmontApi.PasskeyTest do
  @moduledoc """
  End-to-end tests for the passkey signup + login endpoints.

  The Wax crypto boundary is replaced by `HarmontApi.WebauthnFake` (configured in
  `config/test.exs`): only the attestation/assertion signature check is faked.
  Everything we own — verification-email send, challenge store/consume, user
  creation, the sign-counter policy, credential persistence, and session minting —
  runs for real against Postgres.

  Signups are open: any email proceeds through the verification ceremony, capped
  only by the platform signup cap.
  """
  use HarmontApi.DataCase, async: false

  import Swoosh.TestAssertions

  alias Harmont.Accounts.ApiToken
  alias Harmont.Accounts.User
  alias Harmont.Accounts.WebauthnChallenge
  alias Harmont.Accounts.WebauthnCredential
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.SignupAttempt
  alias Harmont.Token

  # Dispatch a JSON POST through the bare router (matches the OAuth-test helper).
  defp post_json(path, params) do
    :post
    |> Plug.Test.conn(path, Jason.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> HarmontApi.Router.call(HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # Drive begin and pull the raw verification token out of the captured email
  # link. `put_email_verification` stores only the hash, so the email is the
  # only place the raw token is observable — which is exactly the real client's
  # vantage point.
  defp begin_and_get_token(email, name) do
    conn = post_json("/api/v0/auth/passkey/signup/begin", %{"email" => email, "name" => name})
    assert conn.status == 204

    assert_received {:email, %Swoosh.Email{text_body: body}}
    assert [_, token] = Regex.run(~r/token=([^\s]+)/, body)
    token
  end

  # ---------------------------------------------------------------------------
  # signup begin
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/signup/begin" do
    test "allowed email -> 204 + verification email + email_verification row + allowed attempt" do
      conn =
        post_json("/api/v0/auth/passkey/signup/begin", %{
          "email" => "alice@harmont.dev",
          "name" => "Alice"
        })

      assert conn.status == 204
      assert_email_sent(fn e -> assert e.subject =~ "Verify your Harmont sign-up" end)

      assert Repo.get_by(Harmont.Accounts.EmailVerification, email: "alice@harmont.dev")

      attempt = Repo.get_by(SignupAttempt, email: "alice@harmont.dev")
      assert attempt.decision == :allowed
      assert attempt.provider == :passkey
    end

    test "begin proceeds for any email (no allowlist gate) -> 204 + verification email; logged :allowed" do
      conn =
        post_json("/api/v0/auth/passkey/signup/begin", %{
          "email" => "anyone@example.com",
          "name" => "Anyone"
        })

      assert conn.status == 204
      assert_email_sent(fn e -> assert e.subject =~ "Verify your Harmont sign-up" end)

      attempt = Repo.get_by(SignupAttempt, email: "anyone@example.com")
      assert attempt.decision == :allowed
      assert attempt.provider == :passkey
    end

    test "begin at capacity -> 503 signup_cap_reached; no email; logged :denied_cap_reached" do
      {:ok, _} = Harmont.Settings.put_signup_cap(0, Repo)

      conn =
        post_json("/api/v0/auth/passkey/signup/begin", %{
          "email" => "full@harmont.dev",
          "name" => "Full"
        })

      assert conn.status == 503
      assert decode(conn)["error"]["code"] == "signup_cap_reached"
      refute_email_sent()

      attempt = Repo.get_by(SignupAttempt, email: "full@harmont.dev")
      assert attempt.decision == :denied_cap_reached
      assert attempt.provider == :passkey
    end
  end

  # ---------------------------------------------------------------------------
  # signup options
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/signup/options" do
    test "valid token -> creation options + stored signup challenge" do
      token = begin_and_get_token("alice@harmont.dev", "Alice")

      conn =
        post_json("/api/v0/auth/passkey/signup/options", %{"verification_token" => token})

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["challenge_id"])
      assert body["options"]["rp"]["id"]
      assert body["options"]["authenticatorSelection"]["userVerification"] == "required"
      assert is_binary(body["options"]["user"]["id"])

      challenge = Repo.get(WebauthnChallenge, body["challenge_id"])
      assert challenge.purpose == :signup
      assert challenge.user_handle != nil
      assert challenge.pending_signup_token_hash == Token.hash(token)
    end

    test "bad token -> passkey_token_invalid" do
      conn =
        post_json("/api/v0/auth/passkey/signup/options", %{"verification_token" => "nope"})

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_token_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # signup finalize
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/signup/finalize" do
    test "fake-verify ok -> 200 token + user + webauthn_credential; challenge consumed" do
      token = begin_and_get_token("alice@harmont.dev", "Alice")

      opts_conn =
        post_json("/api/v0/auth/passkey/signup/options", %{"verification_token" => token})

      challenge_id = decode(opts_conn)["challenge_id"]

      conn =
        post_json("/api/v0/auth/passkey/signup/finalize", %{
          "challenge_id" => challenge_id,
          "verification_token" => token,
          "attestation" => %{"_fake" => "ok"}
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert body["user"]["email"] == "alice@harmont.dev"

      user = Repo.get_by(User, email: "alice@harmont.dev")
      assert user
      assert Repo.get(Organization, user.personal_org_id)

      cred = Repo.get_by(WebauthnCredential, user_id: user.id)
      assert cred
      assert cred.nickname == "Passkey"

      # Challenge + verification token are single-use: both gone.
      assert Repo.get(WebauthnChallenge, challenge_id) == nil
      refute Repo.get_by(Harmont.Accounts.EmailVerification, email: "alice@harmont.dev")

      # The session token validates.
      assert {:ok, ^user} =
               Harmont.Accounts.validate_bearer(body["token"], DateTime.utc_now(), Repo)
    end

    test "missing/expired challenge -> passkey_challenge_invalid" do
      conn =
        post_json("/api/v0/auth/passkey/signup/finalize", %{
          "challenge_id" => Ecto.UUID.generate(),
          "verification_token" => "whatever",
          "attestation" => %{"_fake" => "ok"}
        })

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_challenge_invalid"
    end

    test "challenge-A paired with a different signup's token-B -> rejected, both rows preserved" do
      # Two independent signups. Each gets its own verification token AND its own challenge.
      token_a = begin_and_get_token("a@harmont.dev", "A")
      token_b = begin_and_get_token("b@harmont.dev", "B")

      challenge_a =
        post_json("/api/v0/auth/passkey/signup/options", %{"verification_token" => token_a})
        |> decode()
        |> Map.fetch!("challenge_id")

      # Attacker holds their own valid token_b but pairs it with challenge_a.
      conn =
        post_json("/api/v0/auth/passkey/signup/finalize", %{
          "challenge_id" => challenge_a,
          "verification_token" => token_b,
          "attestation" => %{"_fake" => "ok"}
        })

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_challenge_invalid"

      # No user was created for either email.
      refute Repo.get_by(User, email: "a@harmont.dev")
      refute Repo.get_by(User, email: "b@harmont.dev")

      # token_b's verification row must NOT have been consumed (the binding check
      # runs before `take_email_verification`), so the legitimate B signup can
      # still proceed.
      assert Repo.get_by(Harmont.Accounts.EmailVerification, email: "b@harmont.dev")
    end
  end

  # ---------------------------------------------------------------------------
  # login options
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/login/options" do
    test "-> request options + stored login challenge" do
      conn = post_json("/api/v0/auth/passkey/login/options", %{})

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["challenge_id"])
      assert body["options"]["allowCredentials"] == []
      assert body["options"]["userVerification"] == "required"

      challenge = Repo.get(WebauthnChallenge, body["challenge_id"])
      assert challenge.purpose == :login
    end
  end

  # ---------------------------------------------------------------------------
  # login finalize
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/login/finalize" do
    # Register a user + credential the slow, real way (drive the signup flow) so
    # login operates against a genuinely persisted credential.
    defp signed_up_user(email) do
      token = begin_and_get_token(email, "Login User")

      challenge_id =
        post_json("/api/v0/auth/passkey/signup/options", %{"verification_token" => token})
        |> decode()
        |> Map.fetch!("challenge_id")

      cred_id_b64 = Base.url_encode64(<<1, 2, 3, 4, 5, 6, 7, 8>>, padding: false)

      post_json("/api/v0/auth/passkey/signup/finalize", %{
        "challenge_id" => challenge_id,
        "verification_token" => token,
        "attestation" => %{"_fake" => "ok", "_cred_id" => cred_id_b64}
      })

      {Repo.get_by(User, email: email), cred_id_b64}
    end

    test "fake-verify ok -> 200 token; sign-counter advanced; last_used_at stamped" do
      {user, cred_id_b64} = signed_up_user("login@harmont.dev")
      assert user

      challenge_id =
        post_json("/api/v0/auth/passkey/login/options", %{})
        |> decode()
        |> Map.fetch!("challenge_id")

      conn =
        post_json("/api/v0/auth/passkey/login/finalize", %{
          "challenge_id" => challenge_id,
          "assertion" => %{"rawId" => cred_id_b64, "_fake" => "ok", "_sign_count" => 5}
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])

      cred = Repo.get_by(WebauthnCredential, user_id: user.id)
      assert cred.sign_count == 5
      assert cred.last_used_at != nil

      # Token mints a real session.
      assert Repo.get_by(ApiToken, token_hash: Token.hash(body["token"]))
    end

    test "unknown credential -> passkey_unknown_credential" do
      challenge_id =
        post_json("/api/v0/auth/passkey/login/options", %{})
        |> decode()
        |> Map.fetch!("challenge_id")

      unknown = Base.url_encode64(<<9, 9, 9, 9>>, padding: false)

      conn =
        post_json("/api/v0/auth/passkey/login/finalize", %{
          "challenge_id" => challenge_id,
          "assertion" => %{"rawId" => unknown, "_fake" => "ok"}
        })

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_unknown_credential"
    end
  end
end
