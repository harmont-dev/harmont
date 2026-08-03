defmodule HarmontVm.Backend.Runloop.ClientTest do
  use ExUnit.Case, async: true

  alias HarmontVm.Backend.Runloop.Client

  # A client wired to the in-test Req.Test stub. `retry: false` keeps error-path
  # assertions fast and deterministic (no transient backoff).
  defp client do
    Client.new(
      api_key: "test-key",
      req_options: [plug: {Req.Test, RunloopClientStub}, retry: false]
    )
  end

  describe "new/1" do
    test "requires an api_key" do
      assert_raise KeyError, fn -> Client.new(base_url: "https://example.test") end
    end

    test "sends a Bearer auth header and resolves paths against the base URL" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
        assert conn.request_path == "/v1/ping"
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} = Client.request(client(), :get, "/v1/ping", [], "ping")
    end
  end

  describe "request/5 success" do
    test "returns the decoded JSON body on 2xx" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        Req.Test.json(conn, %{"id" => "dbx_1", "status" => "running"})
      end)

      assert {:ok, %{"id" => "dbx_1", "status" => "running"}} =
               Client.request(client(), :get, "/v1/devboxes/dbx_1", [], "get")
    end

    test "forwards the method, path, and JSON body to the request" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/devboxes/dbx_1/execute_sync"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"command" => "echo hi"}
        Req.Test.json(conn, %{"exit_status" => 0})
      end)

      assert {:ok, %{"exit_status" => 0}} =
               Client.request(
                 client(),
                 :post,
                 "/v1/devboxes/dbx_1/execute_sync",
                 [json: %{command: "echo hi"}],
                 "exec"
               )
    end
  end

  describe "request/5 error rendering" do
    test "maps a non-2xx with a JSON object body to http_<status> + its message" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"message":"boom"}))
      end)

      assert {:error, %{code: "http_500", message: "boom"}} =
               Client.request(client(), :post, "/v1/devboxes", [json: %{}], "create")
    end

    test "decodes a JSON error body delivered as a raw (non-JSON-typed) string" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        # No application/json content type: Req leaves the body as a binary, so
        # the client's Jason fallback must kick in to extract the message.
        Plug.Conn.send_resp(conn, 502, ~s({"error":"upstream"}))
      end)

      assert {:error, %{code: "http_502", message: "upstream"}} =
               Client.request(client(), :get, "/v1/devboxes/x", [], "get")
    end

    test "falls back to the raw body when a non-2xx body is not JSON" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        Plug.Conn.send_resp(conn, 503, "service unavailable")
      end)

      assert {:error, %{code: "http_503", message: "service unavailable"}} =
               Client.request(client(), :get, "/v1/devboxes/x", [], "get")
    end

    test "maps a 404 with no useful body to http_404" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({}))
      end)

      assert {:error, %{code: "http_404"}} =
               Client.request(client(), :post, "/v1/devboxes/x/shutdown", [json: %{}], "shutdown")
    end

    test "maps a transport failure to transport_error" do
      Req.Test.stub(RunloopClientStub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %{code: "transport_error", message: message}} =
               Client.request(client(), :get, "/v1/devboxes/x", [], "get")

      assert is_binary(message) and message != ""
    end
  end

  describe "telemetry" do
    test "emits a request span with operation/method/path metadata" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:harmont_vm, :runloop, :request, :stop]])

      Req.Test.stub(RunloopClientStub, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      assert {:ok, _} = Client.request(client(), :get, "/v1/ping", [], "runloop.ping")

      assert_received {[:harmont_vm, :runloop, :request, :stop], ^ref, _measurements,
                       %{operation: "runloop.ping", method: :get, path: "/v1/ping"}}
    end
  end
end
