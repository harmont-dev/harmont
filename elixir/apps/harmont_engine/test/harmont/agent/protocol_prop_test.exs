defmodule Harmont.Agent.ProtocolPropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Harmont.Agent.Protocol
  alias Harmont.Agent.V1, as: PB
  import StreamData

  property "decode_agent(encode(AgentFrame)) round-trips a LogChunk" do
    check all(
            seq <- positive_integer(),
            ts <- positive_integer(),
            data <- binary(),
            stream <- member_of([:STDOUT, :STDERR, :META])
          ) do
      frame = %PB.AgentFrame{
        payload: {:log, %PB.LogChunk{seq: seq, ts_unix_ns: ts, stream: stream, data: data}}
      }

      bin = PB.AgentFrame.encode(frame)

      assert {:log, %PB.LogChunk{seq: ^seq, ts_unix_ns: ^ts, stream: ^stream, data: ^data}} =
               Protocol.decode_agent(bin)
    end
  end

  property "encode_resume_info / decode_server round-trips server_max_seq" do
    check all(
            n <- non_negative_integer(),
            already <- boolean()
          ) do
      assert {:resume, %PB.ResumeInfo{server_max_seq: ^n, spec_already_sent: ^already}} =
               Protocol.decode_server(Protocol.encode_resume_info(n, already))
    end
  end

  property "encode_cancel / decode_server round-trips the reason" do
    check all(reason <- string(:printable)) do
      assert {:cancel, %PB.CancelMsg{reason: ^reason}} =
               Protocol.decode_server(Protocol.encode_cancel(reason))
    end
  end

  property "encode_error / decode_server round-trips code + detail" do
    check all(
            detail <- string(:printable),
            code <- member_of([:UNKNOWN, :UNAUTHORIZED, :JOB_NOT_FOUND, :PROTO_INCOMPATIBLE])
          ) do
      assert {:error, %PB.ErrorMsg{code: ^code, detail: ^detail}} =
               Protocol.decode_server(Protocol.encode_error(code, detail))
    end
  end
end
