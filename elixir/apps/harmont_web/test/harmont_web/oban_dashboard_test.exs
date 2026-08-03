defmodule HarmontWeb.ObanDashboardTest do
  @moduledoc """
  The Oban Web dashboard is an internal ops surface that exposes job
  args/meta and cancel/retry controls, so it MUST sit behind real HTTP Basic
  auth. These tests pin both halves of that contract: 401 (with a
  `www-authenticate` challenge) for anyone without valid admin creds, and a
  rendered LiveView dashboard for an authenticated admin. Creds come from
  `config :harmont_web, :oban_dashboard` (test.exs); prod sources them from
  env in runtime.exs.
  """
  # async: false — the render test starts a process under the global `Oban`
  # instance's registry (see setup), which is shared across the node.
  use HarmontWeb.ConnCase, async: false

  # Oban Web's connectivity widget calls `Oban.Notifier.status/1`, which talks to
  # the `Oban.Sonar` process. Sonar's `start_link/1` returns `:ignore` whenever
  # the instance runs in a testing mode (ours is `testing: :manual`), so the
  # process never exists and the dashboard render would crash with `:noproc`.
  # For the render assertion we start a real Sonar directly under the `Oban`
  # registry name (bypassing the testing-mode guard); it reports `:unknown` and
  # answers `:get_status`, which is all the widget needs. This is a test-only
  # accommodation — production runs Oban in `:disabled` mode where Sonar starts
  # itself. Idempotent across re-runs (`:already_started` is fine).
  setup do
    conf = Oban.config(Oban)
    name = Oban.Registry.via(Oban, Oban.Sonar)
    state = struct!(Oban.Sonar, conf: conf)

    case GenServer.start(Oban.Sonar, state, name: name) do
      {:ok, pid} -> on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "GET /ops/oban without admin creds is rejected", %{conn: conn} do
    conn = get(conn, "/ops/oban")
    assert response(conn, 401)
    assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="ops")]
  end

  test "GET /ops/oban with wrong admin creds is rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:wrong"))
      |> get("/ops/oban")

    assert response(conn, 401)
  end

  test "GET /ops/oban with admin creds renders the dashboard", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:secret"))
      |> get("/ops/oban")

    assert html_response(conn, 200)
  end
end
