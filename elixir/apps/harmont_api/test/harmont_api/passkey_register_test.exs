defmodule HarmontApi.PasskeyRegisterTest do
  @moduledoc """
  End-to-end tests for the authed passkey-register (add-a-passkey) endpoints.

  The Wax crypto boundary is faked by `HarmontApi.WebauthnFake`; everything else
  (the bearer plug, challenge store/consume, credential persistence) runs for
  real against Postgres.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Accounts.Webauthn
  alias Harmont.Accounts.WebauthnChallenge
  alias Harmont.Accounts.WebauthnCredential

  defp insert_user(email \\ "register@harmont.dev") do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Reg User", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp seed_credential(user, raw_id) do
    {:ok, cred} =
      Webauthn.store_credential(
        %{
          credential_id: raw_id,
          user_handle: :crypto.strong_rand_bytes(16),
          public_key: :crypto.strong_rand_bytes(64),
          sign_count: 0,
          user_id: user.id
        },
        Repo
      )

    cred
  end

  # Dispatch a JSON POST through the bare router, optionally with a bearer token.
  defp post_json(path, params, opts \\ []) do
    conn =
      :post
      |> Plug.Test.conn(path, Jason.encode!(params))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, params)
      |> Map.put(:params, params)

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # register options
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/register/options" do
    test "authed -> options + register challenge excluding existing creds" do
      user = insert_user()
      existing = seed_credential(user, <<7, 7, 7, 7, 7, 7, 7, 7>>)

      conn =
        post_json("/api/v0/auth/passkey/register/options", %{}, bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["challenge_id"])
      assert body["options"]["rp"]["id"]

      # The existing credential id is excluded (Base64url-encoded).
      excluded =
        body["options"]["excludeCredentials"] |> Enum.map(& &1["id"])

      assert Base.url_encode64(existing.credential_id, padding: false) in excluded

      challenge = Repo.get(WebauthnChallenge, body["challenge_id"])
      assert challenge.purpose == :register
      assert challenge.user_id == user.id
      assert challenge.user_handle != nil
    end

    test "unauthed -> 401" do
      conn = post_json("/api/v0/auth/passkey/register/options", %{})
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end
  end

  # ---------------------------------------------------------------------------
  # register finalize
  # ---------------------------------------------------------------------------

  describe "POST /auth/passkey/register/finalize" do
    test "fake-verify ok -> 200 new passkey for current_user; count increases" do
      user = insert_user()
      seed_credential(user, <<1, 1, 1, 1>>)

      before = user.id |> Webauthn.list_credentials(Repo) |> length()

      challenge_id =
        post_json("/api/v0/auth/passkey/register/options", %{}, bearer: bearer_for(user))
        |> decode()
        |> Map.fetch!("challenge_id")

      new_cred_id = Base.url_encode64(<<2, 2, 2, 2, 2, 2>>, padding: false)

      conn =
        post_json(
          "/api/v0/auth/passkey/register/finalize",
          %{
            "challenge_id" => challenge_id,
            "attestation" => %{"_fake" => "ok", "_cred_id" => new_cred_id},
            "nickname" => "Work laptop"
          },
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["uuid"])
      assert body["nickname"] == "Work laptop"
      assert is_binary(body["created_at"])

      after_count = user.id |> Webauthn.list_credentials(Repo) |> length()
      assert after_count == before + 1
      assert Repo.get(WebauthnChallenge, challenge_id) == nil
    end

    test "duplicate credential_id -> 409 passkey_already_registered" do
      user = insert_user()
      dup_raw = <<3, 3, 3, 3>>
      seed_credential(user, dup_raw)

      challenge_id =
        post_json("/api/v0/auth/passkey/register/options", %{}, bearer: bearer_for(user))
        |> decode()
        |> Map.fetch!("challenge_id")

      dup_b64 = Base.url_encode64(dup_raw, padding: false)

      conn =
        post_json(
          "/api/v0/auth/passkey/register/finalize",
          %{
            "challenge_id" => challenge_id,
            "attestation" => %{"_fake" => "ok", "_cred_id" => dup_b64}
          },
          bearer: bearer_for(user)
        )

      assert conn.status == 409
      assert decode(conn)["error"]["code"] == "passkey_already_registered"
    end

    test "unauthed -> 401" do
      conn =
        post_json("/api/v0/auth/passkey/register/finalize", %{
          "challenge_id" => Ecto.UUID.generate(),
          "attestation" => %{"_fake" => "ok"}
        })

      assert conn.status == 401
    end

    test "another user's challenge -> passkey_challenge_invalid" do
      owner = insert_user("owner@harmont.dev")
      attacker = insert_user("attacker@harmont.dev")

      challenge_id =
        post_json("/api/v0/auth/passkey/register/options", %{}, bearer: bearer_for(owner))
        |> decode()
        |> Map.fetch!("challenge_id")

      conn =
        post_json(
          "/api/v0/auth/passkey/register/finalize",
          %{
            "challenge_id" => challenge_id,
            "attestation" => %{
              "_fake" => "ok",
              "_cred_id" => Base.url_encode64(<<5, 5>>, padding: false)
            }
          },
          bearer: bearer_for(attacker)
        )

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_challenge_invalid"
      refute Repo.get_by(WebauthnCredential, user_id: attacker.id)
    end
  end
end
