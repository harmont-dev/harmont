defmodule Freestyle.FacadeTest do
  use Freestyle.ApiCase, async: true

  @tag stub: __MODULE__
  test "who_am_i is delegated", %{client: client, stub: stub} do
    expect_json(stub, fn conn -> assert conn.request_path == "/auth/v1/whoami" end, 200, %{
      "accountId" => "a"
    })

    assert {:ok, %Freestyle.Types.Auth.WhoAmI{account_id: "a"}} = Freestyle.who_am_i(client)
  end

  @tag stub: __MODULE__
  test "who_am_i! unwraps the value", %{client: client, stub: stub} do
    expect_json(stub, fn _ -> :ok end, 200, %{"accountId" => "a"})
    assert %Freestyle.Types.Auth.WhoAmI{account_id: "a"} = Freestyle.who_am_i!(client)
  end

  @tag stub: __MODULE__
  test "bang variant raises a Freestyle.Error on failure", %{client: client, stub: stub} do
    expect_json(stub, fn _ -> :ok end, 404, %{"code" => "NOT_FOUND", "message" => "gone"})

    assert_raise Freestyle.Error, "gone", fn ->
      Freestyle.who_am_i!(client)
    end
  end

  test "unwrap!/1 raises on error tuples" do
    assert Freestyle.unwrap!({:ok, 42}) == 42

    assert_raise Freestyle.Error, fn ->
      Freestyle.unwrap!({:error, %Freestyle.Error{message: "x"}})
    end
  end
end
