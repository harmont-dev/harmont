defmodule HarmontApi.Controllers.UserControllerTest do
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

  defp patch_json(path, params, opts), do: req(:patch, path, params, opts)
  defp delete_json(path, opts), do: req(:delete, path, nil, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "PATCH updates the display name" do
    user = user_fixture("p@example.com")
    conn = patch_json("/api/v0/user", %{"name" => "New Name"}, bearer: bearer_for(user))

    assert conn.status == 200
    assert decode(conn)["name"] == "New Name"
  end

  test "PATCH rejects a blank name with 422" do
    user = user_fixture("p2@example.com")
    conn = patch_json("/api/v0/user", %{"name" => ""}, bearer: bearer_for(user))

    assert conn.status == 422
    assert decode(conn)["error"]["code"] == "user_name_invalid"
  end

  test "DELETE removes the account" do
    user = user_fixture("d@example.com")
    conn = delete_json("/api/v0/user", bearer: bearer_for(user))

    assert conn.status == 204
    assert Repo.get(Harmont.Accounts.User, user.id) == nil
  end

  test "both require auth" do
    assert patch_json("/api/v0/user", %{"name" => "x"}, []).status == 401
    assert delete_json("/api/v0/user", []).status == 401
  end
end
