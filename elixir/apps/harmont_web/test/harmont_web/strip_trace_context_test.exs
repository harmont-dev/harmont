defmodule HarmontWeb.StripTraceContextTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias HarmontWeb.StripTraceContext

  defp call(headers) do
    conn = conn(:post, "/webhooks/github")
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    StripTraceContext.call(conn, StripTraceContext.init([]))
  end

  test "removes traceparent, tracestate, and x-cloud-trace-context" do
    conn =
      call([
        {"traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"},
        {"tracestate", "rojo=00f067aa0ba902b7"},
        {"x-cloud-trace-context", "105445aa7843bc8bf206b12000100000/1;o=1"},
        {"x-github-event", "push"}
      ])

    assert Plug.Conn.get_req_header(conn, "traceparent") == []
    assert Plug.Conn.get_req_header(conn, "tracestate") == []
    assert Plug.Conn.get_req_header(conn, "x-cloud-trace-context") == []
  end

  test "leaves all other headers intact" do
    conn = call([{"x-github-event", "push"}, {"x-hub-signature-256", "sha256=abc"}])

    assert Plug.Conn.get_req_header(conn, "x-github-event") == ["push"]
    assert Plug.Conn.get_req_header(conn, "x-hub-signature-256") == ["sha256=abc"]
  end

  test "is a no-op when no trace headers are present" do
    conn = call([{"content-type", "application/json"}])
    assert conn.req_headers == [{"content-type", "application/json"}]
  end
end
