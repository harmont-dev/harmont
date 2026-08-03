defmodule Harmont.Agent.ProtocolTest do
  use ExUnit.Case, async: true

  alias Harmont.Agent.Protocol
  alias Harmont.Agent.V1, as: AgentPB

  test "decodes a Hello AgentFrame from bytes" do
    bin =
      %AgentPB.AgentFrame{
        payload:
          {:hello,
           %AgentPB.HelloMsg{
             instance_id: "i",
             proto_version: 1,
             build_id: "b",
             job_id: "j",
             last_acked_seq: 0
           }}
      }
      |> AgentPB.AgentFrame.encode()

    assert {:hello, hello} = Protocol.decode_agent(bin)
    assert hello.job_id == "j"
  end

  test "encodes a ServerFrame ResumeInfo to bytes" do
    bin = Protocol.encode_resume_info(7, false)
    assert {:resume, %{server_max_seq: 7}} = Protocol.decode_server(bin)
  end
end
