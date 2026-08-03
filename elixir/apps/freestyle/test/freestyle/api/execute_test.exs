defmodule Freestyle.Api.ExecuteTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Execute
  alias Freestyle.Page
  alias Freestyle.Types.Execute.{Deployment, ExecuteResult, ExecuteScriptOpts}

  @tag stub: __MODULE__
  test "execute_script_v3 posts script and decodes result", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/execute/v3/script"
        {body, _} = read_json(conn)
        assert body == %{"script" => "console.log(1)"}
      end,
      200,
      %{"result" => 1, "logs" => []}
    )

    assert {:ok, %ExecuteResult{result: 1, logs: []}} =
             Execute.execute_script_v3(client, %ExecuteScriptOpts{code: "console.log(1)"})
  end

  @tag stub: __MODULE__
  test "list_deployments decodes a page", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/v1/deployments"
      end,
      200,
      %{"items" => [%{"id" => "dep-1", "status" => "ready"}], "total" => 1}
    )

    assert {:ok, %Page{items: [%Deployment{id: "dep-1"}]}} = Execute.list_deployments(client)
  end
end
