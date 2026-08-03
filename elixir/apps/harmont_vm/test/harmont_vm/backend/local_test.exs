defmodule HarmontVm.Backend.LocalTest do
  use ExUnit.Case, async: true
  alias HarmontVm.Backend.Local

  test "provision/await/exec/teardown round-trip" do
    spec = %{cpu_count: 2, memory_gb: 4.0, disk_gb: 20.0, name: "test-vm"}
    assert {:ok, handle} = Local.provision(spec)
    assert :ok = Local.await_ready(handle, 1_000)

    assert {:ok, %{exit_code: 0, stdout: out}} =
             Local.exec(handle, %{command: "echo hi", hard_cap_ms: 5_000})

    assert out =~ "hi"
    assert :ok = Local.teardown(handle)
  end

  test "non-zero exit is reported, not an error" do
    {:ok, h} = Local.provision(%{cpu_count: 1, memory_gb: 1.0, disk_gb: 1.0, name: "t"})
    assert {:ok, %{exit_code: 3}} = Local.exec(h, %{command: "exit 3", hard_cap_ms: 5_000})
  end

  test "exec honors hard_cap_ms and returns {:error, :timed_out}" do
    {:ok, h} = Local.provision(%{cpu_count: 1, memory_gb: 1.0, disk_gb: 1.0, name: "t"})
    assert {:error, :timed_out} = Local.exec(h, %{command: "sleep 5", hard_cap_ms: 100})
  end
end
