defmodule HarmontVm.Backend.Daytona.ClientTest do
  use ExUnit.Case, async: true
  alias HarmontVm.Backend.Daytona.Client

  defp client do
    Client.new(
      api_key: "test-key",
      req_options: [plug: {Req.Test, DaytonaClientStub}, retry: false]
    )
  end

  test "sends Bearer auth and returns {:ok, body} on 2xx for an absolute URL" do
    Req.Test.stub(DaytonaClientStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert conn.host == "app.daytona.io"
      assert conn.request_path == "/api/sandbox"
      Req.Test.json(conn, %{"id" => "sb_1", "state" => "started"})
    end)

    assert {:ok, %{"id" => "sb_1"}} =
             Client.request(
               client(),
               :post,
               "https://app.daytona.io/api/sandbox",
               [json: %{}],
               "daytona.sandbox.create"
             )
  end

  test "maps non-2xx to {:error, %{code: http_<status>, message}}" do
    Req.Test.stub(DaytonaClientStub, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Plug.Conn.send_resp(404, ~s({"message":"nope"}))
    end)

    assert {:error, %{code: "http_404", message: "nope"}} =
             Client.request(
               client(),
               :get,
               "https://app.daytona.io/api/sandbox/x",
               [],
               "daytona.sandbox.get"
             )
  end

  test "maps a transport error to {:error, %{code: transport_error}}" do
    Req.Test.stub(DaytonaClientStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %{code: "transport_error"}} =
             Client.request(
               client(),
               :get,
               "https://app.daytona.io/api/sandbox",
               [],
               "daytona.sandbox.list"
             )
  end
end
