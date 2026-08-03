defmodule HarmontApi.UserTest do
  @moduledoc """
  End-to-end tests for the authed current-user, passkey-management, and logout
  endpoints. The bearer plug, challenge/credential persistence, token
  revocation, and personal-org resolution all run for real against Postgres.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Accounts.Webauthn
  alias Harmont.Accounts.WebauthnCredential

  # Create a user with a personal org (mirrors the OAuth upsert path) so the
  # personal_org_slug is populated.
  defp create_user(email \\ "user@harmont.dev", name \\ "U Ser") do
    {:ok, user, _created?} =
      Accounts.find_or_create_user_from_identity(
        %{provider: :google, provider_id: "g-" <> email, email: email, name: name},
        DateTime.utc_now(),
        Repo
      )

    user
  end

  defp bare_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Bare", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp seed_credential(user, opts \\ []) do
    {:ok, cred} =
      Webauthn.store_credential(
        %{
          credential_id: :crypto.strong_rand_bytes(16),
          user_handle: :crypto.strong_rand_bytes(16),
          public_key: :crypto.strong_rand_bytes(64),
          sign_count: 0,
          aaguid: Keyword.get(opts, :aaguid),
          nickname: Keyword.get(opts, :nickname),
          user_id: user.id
        },
        Repo
      )

    cred
  end

  defp req(method, path, params, opts) do
    body = if params == nil, do: "", else: Jason.encode!(params)

    conn =
      method
      |> Plug.Test.conn(path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, params || %{})
      |> Map.put(:params, params || %{})

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp get_json(path, opts \\ []), do: req(:get, path, nil, opts)
  defp delete_json(path, opts \\ []), do: req(:delete, path, nil, opts)
  defp patch_json(path, params, opts \\ []), do: req(:patch, path, params, opts)
  defp post_json(path, params, opts \\ []), do: req(:post, path, params, opts)

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # GET /user
  # ---------------------------------------------------------------------------

  describe "GET /user" do
    test "authed -> 200 with the user fields incl personal_org_slug" do
      user = create_user("alice@harmont.dev", "Alice")

      conn = get_json("/api/v0/user", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert body["uuid"] == user.id
      assert body["email"] == "alice@harmont.dev"
      assert body["name"] == "Alice"
      assert is_binary(body["personal_org_slug"])
    end

    test "unauthed -> 401" do
      conn = get_json("/api/v0/user")
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /user/passkeys
  # ---------------------------------------------------------------------------

  describe "GET /user/passkeys" do
    test "lists the user's credentials" do
      user = create_user()
      seed_credential(user, nickname: "Laptop", aaguid: "aa-1")
      seed_credential(user, nickname: "Phone")

      conn = get_json("/api/v0/user/passkeys", bearer: bearer_for(user))

      assert conn.status == 200
      passkeys = decode(conn)["passkeys"]
      assert length(passkeys) == 2
      nicknames = Enum.map(passkeys, & &1["nickname"]) |> Enum.sort()
      assert nicknames == ["Laptop", "Phone"]
      assert Enum.all?(passkeys, &is_binary(&1["uuid"]))
      assert Enum.all?(passkeys, &is_binary(&1["created_at"]))
    end

    test "only lists the current user's credentials" do
      user = create_user("mine@harmont.dev")
      other = create_user("theirs@harmont.dev")
      seed_credential(user, nickname: "Mine")
      seed_credential(other, nickname: "Theirs")

      conn = get_json("/api/v0/user/passkeys", bearer: bearer_for(user))
      passkeys = decode(conn)["passkeys"]
      assert length(passkeys) == 1
      assert hd(passkeys)["nickname"] == "Mine"
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /user/passkeys/:uuid
  # ---------------------------------------------------------------------------

  describe "DELETE /user/passkeys/:uuid" do
    test "deleting one of two -> 204, count drops to 1" do
      user = create_user()
      cred1 = seed_credential(user)
      _cred2 = seed_credential(user)

      conn = delete_json("/api/v0/user/passkeys/#{cred1.id}", bearer: bearer_for(user))

      assert conn.status == 204
      assert Repo.get(WebauthnCredential, cred1.id) == nil
      assert length(Webauthn.list_credentials(user.id, Repo)) == 1
    end

    test "deleting the last remaining -> 409 passkey_last_credential" do
      user = create_user()
      cred = seed_credential(user)

      conn = delete_json("/api/v0/user/passkeys/#{cred.id}", bearer: bearer_for(user))

      assert conn.status == 409
      assert decode(conn)["error"]["code"] == "passkey_last_credential"
      assert Repo.get(WebauthnCredential, cred.id) != nil
    end

    test "deleting another user's passkey -> 404 (scoping)" do
      user = create_user("a@harmont.dev")
      other = create_user("b@harmont.dev")
      _user_cred = seed_credential(user)
      other_cred = seed_credential(other)
      _other_cred2 = seed_credential(other)

      conn = delete_json("/api/v0/user/passkeys/#{other_cred.id}", bearer: bearer_for(user))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "passkey_not_found"
      assert Repo.get(WebauthnCredential, other_cred.id) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # POST /auth/logout
  # ---------------------------------------------------------------------------

  describe "POST /auth/logout" do
    test "204 + the token is revoked (subsequent GET /user -> 401)" do
      user = bare_user("logout@harmont.dev")
      token = bearer_for(user)

      assert get_json("/api/v0/user", bearer: token).status == 200

      conn = post_json("/api/v0/auth/logout", %{}, bearer: token)
      assert conn.status == 204

      assert get_json("/api/v0/user", bearer: token).status == 401
    end
  end
end
