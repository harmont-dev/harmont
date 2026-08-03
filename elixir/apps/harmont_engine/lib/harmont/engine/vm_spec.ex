defmodule Harmont.Engine.VmSpec do
  @moduledoc """
  The canonical compute shape for a job VM. ONE source of truth so the resources
  we *provision* (`Session.provision_vm/2`) and the resources we *bill*
  (`Metering` -> `Billing.record_lease/2`) can never drift apart.
  """

  @cpu_count 2
  @memory_gb 4.0
  @disk_gb 20.0

  @doc "Resources to provision a job VM with (floats, as the VM backend expects)."
  @spec resources() :: %{cpu_count: pos_integer(), memory_gb: float(), disk_gb: float()}
  def resources, do: %{cpu_count: @cpu_count, memory_gb: @memory_gb, disk_gb: @disk_gb}

  @doc "Resources to record on a VM lease (integers, as `vm_leases` stores them)."
  @spec lease_resources() ::
          %{cpu_count: pos_integer(), memory_gb: pos_integer(), disk_gb: pos_integer()}
  def lease_resources,
    do: %{cpu_count: @cpu_count, memory_gb: round(@memory_gb), disk_gb: round(@disk_gb)}
end
