defmodule Freestyle.Api.IdentityTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Identity, as: IdentityApi
  alias Freestyle.Types.Identity.{GitPermission, GrantGitPermissionOpts, Identity, IdentityToken}

  @tag stub: __MODULE__
  test "create_identity posts empty body", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.method == "POST"
        {body, _} = read_json(conn)
        assert body == %{}
      end,
      200,
      %{"id" => "id-1", "managed" => false}
    )

    assert {:ok, %Identity{id: "id-1", managed: false}} = IdentityApi.create_identity(client)
  end

  @tag stub: __MODULE__
  test "list_tokens unwraps {tokens:[...]}", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/identity/v1/identities/id-1/tokens"
      end,
      200,
      %{"tokens" => [%{"id" => "tok-1", "value" => nil}]}
    )

    assert {:ok, [%IdentityToken{id: "tok-1", value: nil}]} =
             IdentityApi.list_tokens(client, "id-1")
  end

  @tag stub: __MODULE__
  test "list_git_permissions unwraps {repositories:[...]} list-item shape", %{
    client: client,
    stub: stub
  } do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/identity/v1/identities/id-1/permissions/git"
      end,
      200,
      %{"repositories" => [%{"id" => "r1", "permissions" => "read"}]}
    )

    assert {:ok, [%GitPermission{repo: "r1", permission: "read"}]} =
             IdentityApi.list_git_permissions(client, "id-1")
  end

  @tag stub: __MODULE__
  test "grant_git_permission returns :ok", %{client: client, stub: stub} do
    expect_empty(
      stub,
      fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/identity/v1/identities/id-1/permissions/git/r1"
      end,
      200
    )

    assert {:ok, :ok} =
             IdentityApi.grant_git_permission(client, "id-1", "r1", %GrantGitPermissionOpts{
               permission: "read"
             })
  end
end
