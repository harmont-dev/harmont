defmodule HarmontApi.Controllers.ApiTokenControllerTest do
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts

  defp user_fixture(email) do
    {:ok, user, _} =
      Accounts.find_or_create_user_from_identity(
        %{provider: :passkey, email: email, name: "T"},
        DateTime.utc_now(),
        Repo
      )

    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
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

  defp get_json(path, opts), do: req(:get, path, nil, opts)
  defp get_json(path), do: req(:get, path, nil, [])
  defp post_json(path, params, opts), do: req(:post, path, params, opts)
  defp delete_json(path, opts), do: req(:delete, path, nil, opts)

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "POST creates a key and returns the one-time secret" do
    user = user_fixture("c@example.com")

    conn =
      post_json("/api/v0/user/api-tokens", %{"description" => "Laptop", "expires_at" => nil},
        bearer: bearer_for(user)
      )

    assert conn.status == 201
    body = decode(conn)

    assert String.starts_with?(body["token"], "hm_")
    assert body["api_token"]["description"] == "Laptop"
    assert body["api_token"]["id"]
    refute Map.has_key?(body["api_token"], "token_hash")
  end

  test "GET lists the user's keys without secrets" do
    user = user_fixture("l@example.com")
    Accounts.create_personal_token(user.id, "one", nil, DateTime.utc_now(), Repo)

    conn = get_json("/api/v0/user/api-tokens", bearer: bearer_for(user))
    assert conn.status == 200
    body = decode(conn)

    assert [key] = body["api_tokens"]
    assert key["description"] == "one"
    refute Map.has_key?(key, "token_hash")
  end

  test "DELETE revokes the user's own key" do
    user = user_fixture("d@example.com")
    {_raw, token} = Accounts.create_personal_token(user.id, "k", nil, DateTime.utc_now(), Repo)

    conn = delete_json("/api/v0/user/api-tokens/#{token.id}", bearer: bearer_for(user))
    assert conn.status == 204
  end

  test "DELETE of another user's key is 404" do
    owner = user_fixture("o@example.com")
    attacker = user_fixture("a@example.com")
    {_raw, token} = Accounts.create_personal_token(owner.id, "k", nil, DateTime.utc_now(), Repo)

    conn = delete_json("/api/v0/user/api-tokens/#{token.id}", bearer: bearer_for(attacker))
    assert conn.status == 404
    body = decode(conn)
    assert body["error"]["code"] == "api_token_not_found"
  end

  test "requires auth" do
    conn = get_json("/api/v0/user/api-tokens")
    assert conn.status == 401
  end
end
