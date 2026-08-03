defmodule Freestyle.Types.IdentityTest do
  use ExUnit.Case, async: true
  alias Freestyle.Types.Identity.GitPermission

  test "GitPermission decodes the single-permission shape" do
    assert {:ok, %GitPermission{repo: "r1", permission: "read"}} =
             GitPermission.decode(%{"repo" => "r1", "accessLevel" => "read"})
  end

  test "GitPermission decodes the list-item shape" do
    assert {:ok, %GitPermission{repo: "r2", permission: "write"}} =
             GitPermission.decode(%{
               "id" => "r2",
               "name" => "x",
               "permissions" => "write",
               "visibility" => "public"
             })
  end
end
