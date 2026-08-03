defmodule Harmont.Engine.VmSpecTest do
  use ExUnit.Case, async: true
  alias Harmont.Engine.VmSpec

  test "lease_resources are positive integers (the vm_leases columns are integers)" do
    r = VmSpec.lease_resources()
    assert is_integer(r.cpu_count) and r.cpu_count > 0
    assert is_integer(r.memory_gb) and r.memory_gb > 0
    assert is_integer(r.disk_gb) and r.disk_gb > 0
  end

  test "provision resources carry the same cpu_count we bill" do
    assert VmSpec.resources().cpu_count == VmSpec.lease_resources().cpu_count
  end
end
