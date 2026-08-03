defmodule HarmontVm.Backend.FreestyleTest do
  use ExUnit.Case, async: true
  alias HarmontVm.Backend.Freestyle

  setup do
    Req.Test.stub(FreestyleStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/vms"} ->
          Req.Test.json(conn, %{"id" => "vm_1", "status" => "running"})

        {"POST", "/v1/vms/vm_1/exec-await"} ->
          Req.Test.json(conn, %{"stdout" => "hi", "stderr" => "", "statusCode" => 0})

        {"DELETE", "/v1/vms/vm_1"} ->
          Req.Test.json(conn, %{})

        {"POST", "/v1/vms/vm_1/snapshot"} ->
          Req.Test.json(conn, %{"snapshotId" => "snap_1", "sourceVmId" => "vm_1"})
      end
    end)

    :ok
  end

  defp spec,
    do: %{
      cpu_count: 2,
      memory_gb: 4.0,
      disk_gb: 20.0,
      name: "job-uuid",
      base_snapshot: nil,
      parent_snapshot: nil
    }

  test "provision -> exec -> snapshot -> teardown" do
    assert {:ok, handle} = Freestyle.provision(spec())

    assert {:ok, %{exit_code: 0, stdout: "hi"}} =
             Freestyle.exec(handle, %{command: "echo hi", hard_cap_ms: 5_000})

    assert {:ok, "snap_1"} = Freestyle.snapshot(handle)
    assert :ok = Freestyle.teardown(handle)
  end

  test "provision error maps to {:error, {:provision_failed, _}}" do
    Req.Test.stub(FreestyleStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))
    end)

    assert {:error, {:provision_failed, render}} = Freestyle.provision(spec())
    # A 500 with no explicit code maps to :internal_server_error, rendered to a
    # stable string code + the API message.
    assert %{code: "internal_server_error", message: "boom"} = render
  end

  test "exec error maps to {:error, {:exec_failed, %{code, message}}}" do
    Req.Test.stub(FreestyleStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/vms"} ->
          Req.Test.json(conn, %{"id" => "vm_1", "status" => "running"})

        {"POST", "/v1/vms/vm_1/exec-await"} ->
          Plug.Conn.send_resp(conn, 403, ~s({"code":"FORBIDDEN","message":"nope"}))
      end
    end)

    assert {:ok, handle} = Freestyle.provision(spec())

    assert {:error, {:exec_failed, %{code: "forbidden", message: "nope"}}} =
             Freestyle.exec(handle, %{command: "echo hi", hard_cap_ms: 5_000})
  end

  test "snapshot error maps to {:error, {:snapshot_failed, %{code, message}}}" do
    Req.Test.stub(FreestyleStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/vms"} ->
          Req.Test.json(conn, %{"id" => "vm_1", "status" => "running"})

        {"POST", "/v1/vms/vm_1/snapshot"} ->
          Plug.Conn.send_resp(conn, 404, ~s({"code":"SNAPSHOT_NOT_FOUND","message":"gone"}))
      end
    end)

    assert {:ok, handle} = Freestyle.provision(spec())

    assert {:error, {:snapshot_failed, %{code: "snapshot_not_found", message: "gone"}}} =
             Freestyle.snapshot(handle)
  end

  test "an unknown wire code is rendered via the {:other, raw} branch" do
    Req.Test.stub(FreestyleStub, fn conn ->
      Plug.Conn.send_resp(conn, 422, ~s({"code":"WEIRD_NEW_CODE","message":"huh"}))
    end)

    # parse_code keeps an unknown code as {:other, "WEIRD_NEW_CODE"}; render/1
    # extracts the raw string.
    assert {:error, {:provision_failed, %{code: "WEIRD_NEW_CODE", message: "huh"}}} =
             Freestyle.provision(spec())
  end

  describe "receive_timeout policy" do
    # The Freestyle client's default 30s receive timeout is far shorter than the
    # synchronous VM operations the backend performs (a `create_vm` boots a real
    # VM; an `exec-await` blocks for the command's whole hard cap). When the
    # client gives up first, a clean server-side result becomes a transport
    # timeout that gets retried 5x — the prod symptom. These pin the per-op
    # timeouts so a regression to a too-short value fails loudly.

    test "exec waits the server's hard cap plus a margin (so the server times out first)" do
      # render exec hard cap (120s) and the longest job cap (~61min) both clear.
      assert Freestyle.exec_receive_timeout(120_000) == 120_000 + 60_000
      assert Freestyle.exec_receive_timeout(3_660_000) == 3_660_000 + 60_000
    end

    test "exec receive timeout always strictly exceeds the server-side hard cap" do
      for cap <- [0, 1, 5_000, 120_000, 3_600_000] do
        assert Freestyle.exec_receive_timeout(cap) > cap
      end
    end

    test "provision/snapshot default to a 120s timeout, well above the 30s client default" do
      assert Freestyle.provision_receive_timeout() == 120_000
      assert Freestyle.provision_receive_timeout() > 30_000
    end
  end
end
