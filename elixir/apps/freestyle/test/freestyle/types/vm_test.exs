defmodule Freestyle.Types.VmTest do
  use ExUnit.Case, async: true

  alias Freestyle.Types.Vm.{
    CpuSpec,
    CreateVmOpts,
    DiskSpec,
    ExecAwaitRequest,
    ExecAwaitResponse,
    MemorySpec,
    SnapshotVmOpts,
    SnapshotVmResponse,
    WriteFileRequest
  }

  test "ExecAwaitRequest omits nil fields on the wire" do
    assert ExecAwaitRequest.encode(%ExecAwaitRequest{command: "ls"}) == %{"command" => "ls"}
  end

  test "ExecAwaitRequest encodes all fields when present" do
    enc =
      ExecAwaitRequest.encode(%ExecAwaitRequest{
        command: "echo hi",
        terminal: "t1",
        timeout_ms: 5000
      })

    assert enc == %{"command" => "echo hi", "terminal" => "t1", "timeoutMs" => 5000}
  end

  test "ExecAwaitResponse decodes nullable fields" do
    assert {:ok, %ExecAwaitResponse{stdout: "hi\n", stderr: nil, status_code: 0}} =
             ExecAwaitResponse.decode(%{"stdout" => "hi\n", "statusCode" => 0})
  end

  test "ExecAwaitResponse decodes a status-only response (no stdout/stderr)" do
    assert {:ok, %ExecAwaitResponse{stdout: nil, stderr: nil, status_code: 1}} =
             ExecAwaitResponse.decode(%{"statusCode" => 1})
  end

  test "ExecAwaitResponse decodes a fully-empty response to all nil" do
    assert {:ok, %ExecAwaitResponse{stdout: nil, stderr: nil, status_code: nil}} =
             ExecAwaitResponse.decode(%{})
  end

  test "FileEncoding serializes to utf-8 / base64 (not utf8)" do
    assert WriteFileRequest.encode(%WriteFileRequest{content: "x", encoding: :utf8}) ==
             %{"content" => "x", "encoding" => "utf-8"}

    assert WriteFileRequest.encode(%WriteFileRequest{content: "x", encoding: :base64})["encoding"] ==
             "base64"
  end

  test "SnapshotVmOpts encodes to an empty object when name is nil" do
    assert SnapshotVmOpts.encode(%SnapshotVmOpts{name: nil}) == %{}
  end

  test "SnapshotVmResponse decodes without sourceVmInstanceId" do
    assert {:ok,
            %SnapshotVmResponse{
              snapshot_id: "sc-x",
              source_vm_id: "vm-y",
              source_vm_instance_id: nil
            }} =
             SnapshotVmResponse.decode(%{"snapshotId" => "sc-x", "sourceVmId" => "vm-y"})
  end

  test "CreateVmOpts encodes nested specs and drops the nil snapshot_id" do
    opts = %CreateVmOpts{
      name: "ci",
      disk: %DiskSpec{size_gb: 6.0},
      memory: %MemorySpec{size_gb: 4.0},
      cpu: %CpuSpec{count: 2}
    }

    assert CreateVmOpts.encode(opts) == %{
             "name" => "ci",
             "disk" => %{"sizeGb" => 6.0},
             "memory" => %{"sizeGb" => 4.0},
             "cpu" => %{"count" => 2}
           }
  end
end
