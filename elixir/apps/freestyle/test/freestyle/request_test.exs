defmodule Freestyle.RequestTest do
  use ExUnit.Case, async: true
  alias Freestyle.{Client, Error, Request}

  setup do
    client = Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])
    {:ok, client: client}
  end

  defp ok_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  test "get/5 decodes a 2xx JSON body via the decoder", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/v1/vms"
      assert conn.params["limit"] == "50"
      ok_json(conn, 200, %{"id" => "vm-1"})
    end)

    decoder = fn body -> {:ok, body["id"]} end
    assert {:ok, "vm-1"} = Request.get(client, "/v1/vms", [limit: 50], decoder, op("list_vms"))
  end

  test "get/5 maps a non-2xx body to an api error", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      ok_json(conn, 404, %{"code" => "NOT_FOUND", "message" => "gone"})
    end)

    decoder = fn _ -> {:ok, :unused} end

    assert {:error, %Error{kind: :api, status: 404, code: :not_found}} =
             Request.get(client, "/v1/vms/x", [], decoder, op("get_vm"))
  end

  test "post/5 sends a JSON body and decodes the response", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"command" => "ls"}
      ok_json(conn, 200, %{"statusCode" => 0})
    end)

    decoder = fn body -> {:ok, body["statusCode"]} end
    assert {:ok, 0} = Request.post(client, "/exec", %{"command" => "ls"}, decoder, op("exec"))
  end

  test "delete/4 returns :ok on 2xx", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert {:ok, :ok} = Request.delete(client, "/v1/vms/x", [], op("delete_vm"))
  end

  test "transport errors become :transport errors", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    decoder = fn _ -> {:ok, :unused} end

    assert {:error, %Error{kind: :transport}} =
             Request.get(client, "/v1/vms", [], decoder, op("list_vms"))
  end

  test "retries a transient 503 then returns the eventual 200", %{client: client} do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if n < 2 do
        Plug.Conn.send_resp(conn, 503, "slow down")
      else
        ok_json(conn, 200, %{"id" => "vm-ok"})
      end
    end)

    decoder = fn body -> {:ok, body["id"]} end
    assert {:ok, "vm-ok"} = Request.get(client, "/v1/vms", [], decoder, op("retry_ok"))
    # Two 503s then a 200 = 3 stub invocations total.
    assert :counters.get(counter, 1) == 3
  end

  test "a 2xx body the decoder rejects becomes a :decode error", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> ok_json(conn, 200, %{"unexpected" => true}) end)
    decoder = fn _ -> {:error, "missing id"} end

    assert {:error, %Error{kind: :decode, status: 200, message: "missing id"}} =
             Request.get(client, "/v1/vms", [], decoder, op("decode_fail"))
  end

  test "get_raw/4 returns raw bytes on 2xx", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, <<1, 2, 3>>) end)
    assert {:ok, <<1, 2, 3>>} = Request.get_raw(client, "/blob", [], op("raw"))
  end

  defp op(name), do: "freestyle.test.#{name}"
end
