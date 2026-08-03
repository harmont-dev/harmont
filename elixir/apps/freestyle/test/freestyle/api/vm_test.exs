defmodule Freestyle.Api.VmTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Vm, as: VmApi
  alias Freestyle.Page

  alias Freestyle.Types.Vm.{
    ExecAwaitRequest,
    ExecAwaitResponse,
    SnapshotVmOpts,
    SnapshotVmResponse,
    Vm,
    WriteFileRequest
  }

  @tag stub: __MODULE__
  test "list_vms decodes a page with the `vms` array key", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/v1/vms"
        assert conn.params["limit"] == "50"
        assert conn.params["offset"] == "0"
      end,
      200,
      %{"vms" => [%{"id" => "vm-1"}], "total" => 1}
    )

    assert {:ok, %Page{items: [%Vm{id: "vm-1"}], total: 1}} = VmApi.list_vms(client)
  end

  @tag stub: __MODULE__
  test "exec_command posts command and decodes the result", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/vms/vm-1/exec-await"
        {body, _} = read_json(conn)
        assert body == %{"command" => "echo hi", "timeoutMs" => 1000}
      end,
      200,
      %{"stdout" => "hi\n", "statusCode" => 0}
    )

    req = %ExecAwaitRequest{command: "echo hi", timeout_ms: 1000}

    assert {:ok, %ExecAwaitResponse{stdout: "hi\n", status_code: 0}} =
             VmApi.exec_command(client, "vm-1", req)
  end

  @tag stub: __MODULE__
  test "put_file percent-encodes slashes in the path", %{client: client, stub: stub} do
    expect_empty(
      stub,
      fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v1/vms/vm-1/files/etc%2Fhosts"
      end,
      200
    )

    req = %WriteFileRequest{content: "127.0.0.1 x", encoding: :utf8}
    assert {:ok, :ok} = VmApi.put_file(client, "vm-1", "etc/hosts", req)
  end

  @tag stub: __MODULE__
  test "snapshot_vm returns the snapshot response", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/v1/vms/vm-1/snapshot"
        {body, _} = read_json(conn)
        assert body == %{}
      end,
      200,
      %{"snapshotId" => "sc-1", "sourceVmId" => "vm-1"}
    )

    assert {:ok, %SnapshotVmResponse{snapshot_id: "sc-1", source_vm_id: "vm-1"}} =
             VmApi.snapshot_vm(client, "vm-1", %SnapshotVmOpts{})
  end

  @tag stub: __MODULE__
  test "delete_vm returns :ok on 204", %{client: client, stub: stub} do
    expect_empty(stub, fn conn -> assert conn.request_path == "/v1/vms/vm-9" end)
    assert {:ok, :ok} = VmApi.delete_vm(client, "vm-9")
  end
end
