defmodule Freestyle.Api.AuthTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Auth
  alias Freestyle.Types.Auth.{BackgroundRequest, WhoAmI}

  @tag stub: __MODULE__
  test "who_am_i decodes accountId", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/auth/v1/whoami"
      end,
      200,
      %{"accountId" => "acct-123"}
    )

    assert {:ok, %WhoAmI{account_id: "acct-123"}} = Auth.who_am_i(client)
  end

  @tag stub: __MODULE__
  test "get_background_request decodes status + result", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/auth/v1/background-requests/req-9"
      end,
      200,
      %{"requestId" => "req-9", "status" => "done", "result" => %{"ok" => true}}
    )

    assert {:ok, %BackgroundRequest{request_id: "req-9", status: "done", result: %{"ok" => true}}} =
             Auth.get_background_request(client, "req-9")
  end
end
