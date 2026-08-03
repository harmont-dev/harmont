defmodule HarmontWeb.HealthzTest do
  @moduledoc """
  The `/healthz` liveness/readiness probe drives the GCE LB health check. It
  returns 200 "ok" normally and 503 "draining" once `Harmont.Drain` has flipped the
  drain flag, so the LB de-registers this backend before the BEAM stops.
  """
  use HarmontWeb.ConnCase, async: false

  alias Harmont.Drain

  setup do
    on_exit(&Drain.reset/0)
    Drain.reset()
    :ok
  end

  test "returns 200 ok when not draining", %{conn: conn} do
    conn = HarmontWeb.Endpoint.healthz(%{conn | request_path: "/healthz"}, [])
    assert conn.status == 200
    assert conn.resp_body == "ok"
    assert conn.halted
  end

  test "returns 503 draining when draining", %{conn: conn} do
    Drain.request_drain(grace_ms: 60_000, stop_fun: fn -> :noop end)

    conn = HarmontWeb.Endpoint.healthz(%{conn | request_path: "/healthz"}, [])
    assert conn.status == 503
    assert conn.resp_body == "draining"
    assert conn.halted
  end
end
