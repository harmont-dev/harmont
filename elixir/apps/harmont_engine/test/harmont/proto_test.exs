defmodule Harmont.ProtoTest do
  use ExUnit.Case, async: true

  test "agent proto modules are generated" do
    assert Code.ensure_loaded?(Harmont.Agent.V1.AgentFrame)
    assert Code.ensure_loaded?(Harmont.Agent.V1.LogChunk)
  end
end
