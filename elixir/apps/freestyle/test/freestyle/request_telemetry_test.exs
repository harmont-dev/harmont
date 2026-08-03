defmodule Freestyle.RequestTelemetryTest do
  use ExUnit.Case, async: true
  alias Freestyle.{Client, Error, Request}

  setup do
    client = Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])
    handler = "rt-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler,
      [
        [:freestyle, :request, :start],
        [:freestyle, :request, :stop],
        [:freestyle, :request, :retry]
      ],
      fn event, measurements, meta, _ -> send(self(), {:tel, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, client: client}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  test "a successful request emits start + stop with operation metadata", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> json(conn, 200, %{"id" => "x"}) end)

    assert {:ok, "x"} =
             Request.get(
               client,
               "/v1/vms",
               [],
               fn b -> {:ok, b["id"]} end,
               "freestyle.vm.list_vms"
             )

    assert_received {:tel, [:freestyle, :request, :start], _,
                     %{operation: "freestyle.vm.list_vms", method: :get, path: "/v1/vms"}}

    assert_received {:tel, [:freestyle, :request, :stop], %{duration: _}, stop}
    assert stop.result == :ok
  end

  test "a 403 tags the stop event with status and error_code", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      json(conn, 403, %{"code" => "FORBIDDEN", "message" => "denied"})
    end)

    assert {:error, %Error{status: 403, code: :forbidden}} =
             Request.get(
               client,
               "/auth/v1/whoami",
               [],
               fn _ -> {:ok, :unused} end,
               "freestyle.auth.who_am_i"
             )

    assert_received {:tel, [:freestyle, :request, :stop], _, stop}
    assert stop.result == :error
    assert stop.status == 403
    assert stop.error_kind == :api
    assert stop.error_code == "forbidden"
    assert stop.error_message == "denied"
  end

  test "a transport failure surfaces :error_kind and :error_message on stop", %{client: client} do
    # The prod symptom: a request that never gets a response. The stop event must
    # carry the transport message ("timeout"-class reason) so a stuck provision is
    # diagnosable — there is no HTTP status or error_code to fall back on.
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Error{kind: :transport}} =
             Request.get(
               client,
               "/v1/vms",
               [],
               fn _ -> {:ok, :unused} end,
               "freestyle.vm.create_vm"
             )

    assert_received {:tel, [:freestyle, :request, :stop], _, stop}
    assert stop.result == :error
    assert stop.error_kind == :transport
    assert stop.status == nil
    assert stop.error_code == nil
    assert stop.error_message == "timeout"
  end

  test "retries a 503 twice then succeeds, emitting a retry event per retry", %{client: client} do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if n < 2, do: Plug.Conn.send_resp(conn, 503, "slow"), else: json(conn, 200, %{"id" => "ok"})
    end)

    assert {:ok, "ok"} =
             Request.get(client, "/x", [], fn b -> {:ok, b["id"]} end, "freestyle.test.retry")

    assert_received {:tel, [:freestyle, :request, :retry], %{delay: _},
                     %{attempt: 1, reason: "http_503"}}

    assert_received {:tel, [:freestyle, :request, :retry], %{delay: _},
                     %{attempt: 2, reason: "http_503"}}

    refute_received {:tel, [:freestyle, :request, :retry], _, %{attempt: 3}}
    assert :counters.get(counter, 1) == 3
  end

  test "stops retrying after the limit and surfaces the last 503 error", %{client: client} do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      json(conn, 503, %{"code" => "INTERNAL_SERVER_ERROR", "message" => "down"})
    end)

    assert {:error, %Error{kind: :api, status: 503, code: :internal_server_error}} =
             Request.get(client, "/x", [], fn _ -> {:ok, :unused} end, "freestyle.test.exhaust")

    # 1 initial attempt + 4 retries
    assert :counters.get(counter, 1) == 5
  end

  test "does not retry a 404 and emits no retry event", %{client: client} do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      json(conn, 404, %{"code" => "NOT_FOUND", "message" => "gone"})
    end)

    assert {:error, %Error{status: 404, code: :not_found}} =
             Request.get(client, "/x", [], fn _ -> {:ok, :unused} end, "freestyle.test.notfound")

    assert :counters.get(counter, 1) == 1
    refute_received {:tel, [:freestyle, :request, :retry], _, _}
  end
end
