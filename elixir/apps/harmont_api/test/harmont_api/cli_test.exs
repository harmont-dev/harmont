defmodule HarmontApi.CliTest do
  @moduledoc """
  End-to-end tests for the CLI auth handoff endpoints.

  `transfer`/`code` run behind the bearer plug; `claim`/`redeem` are public.
  Everything (token minting, single-use handoff, expiry) runs for real against
  Postgres. Each test verifies the handed-off token actually validates via
  `Accounts.validate_bearer`.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User

  defp insert_user(email \\ "cli@harmont.dev") do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "CLI User", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

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
  # transfer + claim (loopback)
  # ---------------------------------------------------------------------------

  describe "loopback: POST /auth/cli/transfer then /auth/cli/claim" do
    test "transfer (authed) parks a token; claim returns a token that validates" do
      user = insert_user()
      nonce = "cli-nonce-1234567890"

      transfer =
        post_json("/api/v0/auth/cli/transfer", %{"nonce" => nonce}, bearer: bearer_for(user))

      assert transfer.status == 204

      claim = post_json("/api/v0/auth/cli/claim", %{"nonce" => nonce})
      assert claim.status == 200
      token = decode(claim)["token"]
      assert is_binary(token)

      assert {:ok, validated} = Accounts.validate_bearer(token, DateTime.utc_now(), Repo)
      assert validated.id == user.id
    end

    test "transfer unauthed -> 401" do
      conn = post_json("/api/v0/auth/cli/transfer", %{"nonce" => "x"})
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end

    test "claim with the wrong nonce -> 400 cli_code_invalid" do
      user = insert_user()

      assert post_json("/api/v0/auth/cli/transfer", %{"nonce" => "right"},
               bearer: bearer_for(user)
             ).status ==
               204

      conn = post_json("/api/v0/auth/cli/claim", %{"nonce" => "wrong"})
      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "cli_code_invalid"
    end

    test "claim is single-use: second claim fails" do
      user = insert_user()
      nonce = "single-use-nonce"

      post_json("/api/v0/auth/cli/transfer", %{"nonce" => nonce}, bearer: bearer_for(user))

      assert post_json("/api/v0/auth/cli/claim", %{"nonce" => nonce}).status == 200
      second = post_json("/api/v0/auth/cli/claim", %{"nonce" => nonce})
      assert second.status == 400
      assert decode(second)["error"]["code"] == "cli_code_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # code + redeem (paste)
  # ---------------------------------------------------------------------------

  describe "paste: POST /auth/cli/code then /auth/cli/redeem" do
    test "code (authed) mints a code; redeem returns a token that validates" do
      user = insert_user()

      code_conn = post_json("/api/v0/auth/cli/code", %{}, bearer: bearer_for(user))
      assert code_conn.status == 200
      code = decode(code_conn)["code"]
      assert is_binary(code)

      redeem = post_json("/api/v0/auth/cli/redeem", %{"code" => code})
      assert redeem.status == 200
      token = decode(redeem)["token"]
      assert is_binary(token)

      assert {:ok, validated} = Accounts.validate_bearer(token, DateTime.utc_now(), Repo)
      assert validated.id == user.id
    end

    test "code unauthed -> 401" do
      conn = post_json("/api/v0/auth/cli/code", %{})
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end

    test "redeem is single-use: second redeem fails" do
      user = insert_user()

      code =
        post_json("/api/v0/auth/cli/code", %{}, bearer: bearer_for(user))
        |> decode()
        |> Map.fetch!("code")

      assert post_json("/api/v0/auth/cli/redeem", %{"code" => code}).status == 200
      second = post_json("/api/v0/auth/cli/redeem", %{"code" => code})
      assert second.status == 400
      assert decode(second)["error"]["code"] == "cli_code_invalid"
    end

    test "redeem with an unknown code -> 400 cli_code_invalid" do
      conn = post_json("/api/v0/auth/cli/redeem", %{"code" => "ZZZZZZZZZZZZZZZZ"})
      assert conn.status == 400
      assert decode(conn)["error"]["code"] == "cli_code_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # TTL boundaries (context-level)
  #
  # The controllers stamp `now` from the wall clock, so expiry can't be driven
  # through the HTTP edge deterministically. `put_/take_cli_*` accept an
  # injectable `now`, so we drive the TTL boundary at the context layer: a token
  # taken past its TTL is rejected; one taken inside the window still validates.
  # ---------------------------------------------------------------------------

  describe "CLI handoff TTL boundaries" do
    # Mirror the context constants: transfer parks for 60s, paste for 300s.
    @transfer_ttl_seconds 60
    @paste_ttl_seconds 300

    # `take_cli_*` is single-use: it deletes the row before checking expiry, so
    # each branch needs its OWN parked record (a rejected take still consumes it).
    test "transfer: a token taken past its TTL is rejected" do
      user = insert_user("ttl-transfer-exp@harmont.dev")
      {raw, _} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
      t0 = ~U[2026-01-01 00:00:00Z]
      nonce = "ttl-transfer-expired"

      :ok = Accounts.put_cli_transfer(raw, nonce, t0, Repo)

      past = DateTime.add(t0, @transfer_ttl_seconds + 1, :second)
      assert Accounts.take_cli_transfer(nonce, past, Repo) == {:error, :invalid}
    end

    test "transfer: a token taken at the TTL boundary is still accepted" do
      user = insert_user("ttl-transfer-edge@harmont.dev")
      {raw, _} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
      t0 = ~U[2026-01-01 00:00:00Z]
      nonce = "ttl-transfer-edge"

      :ok = Accounts.put_cli_transfer(raw, nonce, t0, Repo)

      edge = DateTime.add(t0, @transfer_ttl_seconds, :second)
      assert {:ok, ^raw} = Accounts.take_cli_transfer(nonce, edge, Repo)
    end

    test "paste: a code taken past its TTL is rejected" do
      user = insert_user("ttl-paste-exp@harmont.dev")
      {raw, _} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
      t0 = ~U[2026-01-01 00:00:00Z]

      {:ok, code} = Accounts.put_cli_paste(raw, t0, Repo)

      past = DateTime.add(t0, @paste_ttl_seconds + 1, :second)
      assert Accounts.take_cli_paste(code, past, Repo) == {:error, :invalid}
    end

    test "paste: a code taken at the TTL boundary is still accepted" do
      user = insert_user("ttl-paste-edge@harmont.dev")
      {raw, _} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
      t0 = ~U[2026-01-01 00:00:00Z]

      {:ok, code} = Accounts.put_cli_paste(raw, t0, Repo)

      edge = DateTime.add(t0, @paste_ttl_seconds, :second)
      assert {:ok, ^raw} = Accounts.take_cli_paste(code, edge, Repo)
    end
  end
end
