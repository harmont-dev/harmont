defmodule HarmontApi.Plugs.AuthTest do
  use HarmontApi.DataCase, async: true

  import Phoenix.ConnTest

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias HarmontApi.Plugs.Auth

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      name: "Auth User",
      email: "auth-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
  end

  defp call(conn), do: Auth.call(conn, Auth.init([]))

  test "assigns current_user for a valid bearer token" do
    user = insert_user!()
    {raw, _token} = Accounts.create_session_token(user.id)

    conn =
      Phoenix.ConnTest.build_conn(:get, "/user")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
      |> call()

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
  end

  test "halts with 401 envelope when no authorization header is present" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/user")
      |> call()

    assert conn.halted
    assert conn.status == 401
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "halts with 401 for a malformed authorization header" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/user")
      |> Plug.Conn.put_req_header("authorization", "Token abc")
      |> call()

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 for an invalid bearer token" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/user")
      |> Plug.Conn.put_req_header("authorization", "Bearer not-a-real-token")
      |> call()

    assert conn.halted
    assert conn.status == 401
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end
end
