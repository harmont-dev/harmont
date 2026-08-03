defmodule Harmont.Agent.Protocol do
  @moduledoc "Thin encode/decode helpers over the generated harmont.agent.v1 modules."
  alias Harmont.Agent.V1, as: PB

  @spec decode_agent(binary()) :: {atom(), struct()} | {:error, term()}
  def decode_agent(bin) do
    case PB.AgentFrame.decode(bin) do
      %PB.AgentFrame{payload: {tag, msg}} -> {tag, msg}
      _ -> {:error, :empty_frame}
    end
  rescue
    e -> {:error, e}
  end

  @spec decode_server(binary()) :: {atom(), struct()}
  def decode_server(bin) do
    %PB.ServerFrame{payload: {tag, msg}} = PB.ServerFrame.decode(bin)
    {tag, msg}
  end

  @spec encode_resume_info(non_neg_integer(), boolean()) :: binary()
  def encode_resume_info(server_max_seq, spec_already_sent) do
    %PB.ServerFrame{
      payload:
        {:resume,
         %PB.ResumeInfo{
           server_max_seq: server_max_seq,
           spec_already_sent: spec_already_sent
         }}
    }
    |> PB.ServerFrame.encode()
  end

  @spec encode_job_spec(map()) :: binary()
  def encode_job_spec(spec) do
    %PB.ServerFrame{
      payload:
        {:spec,
         %PB.JobSpec{
           command: spec.command,
           env: spec[:env] || %{},
           timeout_sec: spec[:timeout_sec] || 3600,
           source_url: spec[:source_url] || "",
           source_sha256: spec[:source_sha256] || "",
           grace_sec: spec[:grace_sec] || 10,
           max_log_bytes: spec[:max_log_bytes] || 0
         }}
    }
    |> PB.ServerFrame.encode()
  end

  @spec encode_cancel(String.t()) :: binary()
  def encode_cancel(reason),
    do:
      %PB.ServerFrame{payload: {:cancel, %PB.CancelMsg{reason: reason}}}
      |> PB.ServerFrame.encode()

  @spec encode_error(atom(), String.t()) :: binary()
  def encode_error(code, detail),
    do:
      %PB.ServerFrame{payload: {:error, %PB.ErrorMsg{code: code, detail: detail}}}
      |> PB.ServerFrame.encode()
end
