defmodule Freestyle.Api.DomainTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Domain
  alias Freestyle.Types.Domain.{DomainMapping, Verification}

  @tag stub: __MODULE__
  test "create_verification posts {domain}", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        {body, _} = read_json(conn)
        assert body == %{"domain" => "example.com"}
      end,
      200,
      %{"domain" => "example.com", "code" => "abc"}
    )

    assert {:ok, %Verification{domain: "example.com", code: "abc"}} =
             Domain.create_verification(client, "example.com")
  end

  @tag stub: __MODULE__
  test "create_mapping posts snake_case deployment_id", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/domains/v1/mappings/example.com"
        {body, _} = read_json(conn)
        assert body == %{"deployment_id" => "dep-1"}
      end,
      200,
      %{"domain" => "example.com", "deploymentId" => "dep-1"}
    )

    assert {:ok, %DomainMapping{domain: "example.com", deployment_id: "dep-1"}} =
             Domain.create_mapping(client, "example.com", {:deployment, "dep-1"})
  end

  @tag stub: __MODULE__
  test "delete_verification sends domain query param", %{client: client, stub: stub} do
    expect_empty(stub, fn conn ->
      assert conn.request_path == "/domains/v1/verifications"
      assert conn.params["domain"] == "example.com"
    end)

    assert {:ok, :ok} = Domain.delete_verification(client, "example.com")
  end
end
