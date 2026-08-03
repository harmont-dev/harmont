defmodule Freestyle.Types.DomainTest do
  use ExUnit.Case, async: true
  alias Freestyle.Types.Domain.CreateMappingOpts

  test "CreateMappingOpts encodes snake_case deployment_id / vm_id" do
    assert CreateMappingOpts.encode({:deployment, "dep-1"}) == %{"deployment_id" => "dep-1"}
    assert CreateMappingOpts.encode({:vm, "vm-1"}) == %{"vm_id" => "vm-1"}
  end

  test "CreateMappingOpts round-trips" do
    assert {:ok, {:deployment, "d"}} = CreateMappingOpts.decode(%{"deployment_id" => "d"})
    assert {:ok, {:vm, "v"}} = CreateMappingOpts.decode(%{"vm_id" => "v"})
  end
end
