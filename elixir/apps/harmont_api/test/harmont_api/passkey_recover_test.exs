defmodule HarmontApi.PasskeyRecoverTest do
  @moduledoc """
  End-to-end tests for the public magic-link recovery endpoints.

  The Wax crypto boundary is faked by `HarmontApi.WebauthnFake`; the magic-link
  store/consume, challenge lifecycle, credential persistence, and session
  minting all run for real against Postgres. Email is captured by
  `Swoosh.Adapters.Test`.
  """
  use HarmontApi.DataCase, async: false

  import Swoosh.TestAssertions

  alias Harmont.Accounts.ApiToken
  alias Harmont.Accounts.MagicLink
  alias Harmont.Accounts.User
  alias Harmont.Accounts.WebauthnCredential
  alias Harmont.Token

  defp insert_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Recover User", email: email}))
    user
  end

  defp post_json(path, params) do
    :post
    |> Plug.Test.conn(path, Jason.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> HarmontApi.Router.call(HarmontApi.Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # Drive begin for an existing user and pull the raw token out of the email
  # (the only place it is observable — `put_magic_link` stores only the hash).
  defp begin_and_get_token(email) do
    conn = post_json("/api/v0/auth/recover/begin", %{"email" => email})
    assert conn.status == 204

    assert_received {:email, %Swoosh.Email{text_body: body}}
    assert [_, token] = Regex.run(~r/token=([^\s]+)/, body)
    token
  end

  # ---------------------------------------------------------------------------
  # recover begin
  # ---------------------------------------------------------------------------

  describe "POST /auth/recover/begin" do
    test "existing email -> 204 + magic_link row + email sent" do
      user = insert_user("known@harmont.dev")

      conn = post_json("/api/v0/auth/recover/begin", %{"email" => "known@harmont.dev"})

      assert conn.status == 204
      assert_email_sent(fn e -> assert e.subject =~ "Recover access" end)
      assert Repo.get_by(MagicLink, user_id: user.id)
    end

    test "unknown email -> 204 + no row + no email (no existence leak)" do
      conn = post_json("/api/v0/auth/recover/begin", %{"email" => "ghost@harmont.dev"})

      assert conn.status == 204
      assert Repo.aggregate(MagicLink, :count) == 0
      refute_received {:email, _}
    end
  end

  # ---------------------------------------------------------------------------
  # recover options
  # ---------------------------------------------------------------------------

  describe "POST /auth/recover/options" do
    test "valid magic link -> options + recover_register challenge" do
      user = insert_user("opt@harmont.dev")
      token = begin_and_get_token("opt@harmont.dev")

      conn = post_json("/api/v0/auth/recover/options", %{"magic_link_token" => token})

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["challenge_id"])
      assert body["options"]["rp"]["id"]

      challenge = Repo.get(Harmont.Accounts.WebauthnChallenge, body["challenge_id"])
      assert challenge.purpose == :recover_register
      assert challenge.user_id == user.id

      # Non-consuming: the magic link is still present.
      assert Repo.get_by(MagicLink, user_id: user.id)
    end

    test "bad token -> passkey_token_invalid" do
      conn = post_json("/api/v0/auth/recover/options", %{"magic_link_token" => "nope"})

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "passkey_token_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # recover finalize
  # ---------------------------------------------------------------------------

  describe "POST /auth/recover/finalize" do
    test "fake-verify ok -> 200 token + new credential; magic link consumed" do
      user = insert_user("fin@harmont.dev")
      token = begin_and_get_token("fin@harmont.dev")

      challenge_id =
        post_json("/api/v0/auth/recover/options", %{"magic_link_token" => token})
        |> decode()
        |> Map.fetch!("challenge_id")

      cred_id = Base.url_encode64(<<10, 20, 30, 40>>, padding: false)

      conn =
        post_json("/api/v0/auth/recover/finalize", %{
          "magic_link_token" => token,
          "challenge_id" => challenge_id,
          "attestation" => %{"_fake" => "ok", "_cred_id" => cred_id}
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["token"])
      assert body["user"]["email"] == "fin@harmont.dev"

      assert Repo.get_by(WebauthnCredential, user_id: user.id)
      # Magic link consumed (single-use).
      refute Repo.get_by(MagicLink, user_id: user.id)
      # Session token mints a real session.
      assert Repo.get_by(ApiToken, token_hash: Token.hash(body["token"]))
    end

    test "reused/expired magic link -> passkey_token_invalid" do
      _user = insert_user("reuse@harmont.dev")
      token = begin_and_get_token("reuse@harmont.dev")

      challenge_id =
        post_json("/api/v0/auth/recover/options", %{"magic_link_token" => token})
        |> decode()
        |> Map.fetch!("challenge_id")

      # Consume the link once successfully.
      first =
        post_json("/api/v0/auth/recover/finalize", %{
          "magic_link_token" => token,
          "challenge_id" => challenge_id,
          "attestation" => %{
            "_fake" => "ok",
            "_cred_id" => Base.url_encode64(<<1>>, padding: false)
          }
        })

      assert first.status == 200

      # Reuse the same (now-consumed) token.
      second =
        post_json("/api/v0/auth/recover/finalize", %{
          "magic_link_token" => token,
          "challenge_id" => Ecto.UUID.generate(),
          "attestation" => %{"_fake" => "ok"}
        })

      assert second.status == 400
      assert decode(second)["error"]["code"] == "passkey_token_invalid"
    end
  end
end
