defmodule Freestyle.WireTest do
  use ExUnit.Case, async: true
  alias Freestyle.Wire

  describe "to_wire_key/1" do
    test "lower-camel-cases snake_case atoms" do
      assert Wire.to_wire_key(:account_id) == "accountId"
      assert Wire.to_wire_key(:timeout_ms) == "timeoutMs"
      assert Wire.to_wire_key(:source_vm_instance_id) == "sourceVmInstanceId"
      assert Wire.to_wire_key(:size_gb) == "sizeGb"
      assert Wire.to_wire_key(:id) == "id"
    end
  end

  describe "from_wire_key/1" do
    test "snake_cases camelCase strings to existing atoms" do
      assert Wire.from_wire_key("accountId") == :account_id
      assert Wire.from_wire_key("timeoutMs") == :timeout_ms
      assert Wire.from_wire_key("id") == :id
    end
  end

  describe "encode/1" do
    test "camel-cases keys and drops nil values" do
      assert Wire.encode(%{command: "ls", terminal: nil, timeout_ms: 5000}) ==
               %{"command" => "ls", "timeoutMs" => 5000}
    end

    test "leaves an empty map empty" do
      assert Wire.encode(%{name: nil}) == %{}
    end
  end

  describe "rekey_in/1" do
    test "translates wire keys to snake_case string keys for casting" do
      assert Wire.rekey_in(%{"accountId" => "a", "id" => "x"}) ==
               %{"account_id" => "a", "id" => "x"}
    end
  end
end
