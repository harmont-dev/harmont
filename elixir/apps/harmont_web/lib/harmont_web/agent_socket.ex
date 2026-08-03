defmodule HarmontWeb.AgentSocket do
  @moduledoc """
  Raw WebSocket handler for the in-VM agent. One protobuf message per binary
  frame. Validates the Bearer runner token on upgrade, replies Hello with
  ResumeInfo + JobSpec, then bridges upstream frames.

  Per REVISION 2026-05-24c:
  - :state frames are routed to Session.agent_event/2 (not Bridge).
  - :log/:heartbeat/:bye frames go to Bridge.apply_frame/3.
  - handle_info(:cancel, ...) forwards a CancelMsg to the agent.
  """
  @behaviour WebSock
  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias Harmont.Agent.{Bridge, Protocol}
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Fsm.JobState
  alias Harmont.Engine.Session
  alias Harmont.Logs.Store
  import Ecto.Query

  @proto_version 1

  # Log chunks are buffered and flushed in batches (one insert_all) rather than a
  # round-trip-per-chunk on the receive path — a per-chunk insert can't drain a
  # heavy compile's output in real time, backpressuring the socket until it
  # stalls and the connection drops mid-job. Flush when the buffer fills OR after
  # a short delay, whichever comes first, so live logs stay near-real-time.
  @log_flush_max 256
  @log_flush_interval_ms 100

  @impl true
  def init(opts) do
    {:ok,
     %{
       token: opts[:token],
       job_id: nil,
       build_id: nil,
       instance_id: nil,
       log_buf: [],
       log_buf_len: 0,
       log_flush_pending: false
     }}
  end

  @impl true
  def handle_in({bin, [opcode: :binary]}, state) do
    case Protocol.decode_agent(bin) do
      {:hello, hello} -> on_hello(hello, state)
      {:error, e} -> {:stop, {:error, e}, state}
      {tag, msg} -> on_frame(tag, msg, state)
    end
  end

  def handle_in({_data, [opcode: :text]}, state), do: {:ok, state}

  @impl true
  def handle_control(_frame, state), do: {:ok, state}

  defp on_hello(hello, state) do
    # The agent connect is the single biggest server-side blind spot: a rejected
    # Hello (proto mismatch, token mismatch, the PK-vs-external-id JOB_NOT_FOUND)
    # produced ZERO telemetry, leaving only the engine's coarse 90s
    # agent_connect_deadline with no reason. The spool-dir EACCES failure is
    # similarly invisible (the agent never sends Hello at all). This span records
    # every handshake outcome. NB: a WS upgrade carries no inbound OTel context,
    # so agent.handshake is a trace ROOT — correlate to the job.run trace via the
    # harmont.job.id / harmont.build.id attributes, not trace-parent linkage.
    Tracer.with_span "agent.handshake", %{
      kind: :server,
      attributes: %{
        "agent.proto_version" => hello.proto_version,
        "agent.instance_id" => hello.instance_id
      }
    } do
      with :ok <- check_proto(hello.proto_version),
           {:ok, build, job} <- authorize(hello, state.token) do
        Tracer.set_attributes(%{
          "handshake.result" => "ok",
          "harmont.job.id" => job.id,
          "harmont.build.id" => job.build_id
        })

        :ok = Phoenix.PubSub.subscribe(Harmont.PubSub, "job_cancel:#{job.id}")
        resume = Protocol.encode_resume_info(Store.max_seq(job.id), false)

        spec =
          Protocol.encode_job_spec(%{
            command: job.command,
            env: job.env,
            timeout_sec: div(job.timeout_ms || 3_600_000, 1000),
            source_url: build_source_url(build),
            grace_sec: 10
          })

        {:push, [{:binary, resume}, {:binary, spec}],
         %{state | job_id: job.id, build_id: job.build_id, instance_id: hello.instance_id}}
      else
        {:error, code} ->
          result = Atom.to_string(code)
          Tracer.set_attribute("handshake.result", result)
          Tracer.add_event("agent.handshake_rejected", %{"handshake.result" => result})
          Tracer.set_status(OpenTelemetry.status(:error, result))
          {:push, {:binary, Protocol.encode_error(code, "")}, state}
      end
    end
  end

  # Log frames: buffer and flush in batches (see @log_flush_max). Never touch the
  # DB per chunk on the receive path.
  defp on_frame(:log, lc, %{job_id: jid} = state) when is_binary(jid) do
    chunk = %{
      seq: lc.seq,
      stream_kind: stream_kind(lc.stream),
      content: lc.data,
      ts_unix_ns: lc.ts_unix_ns,
      instance_id: state.instance_id
    }

    state = %{state | log_buf: [chunk | state.log_buf], log_buf_len: state.log_buf_len + 1}

    cond do
      state.log_buf_len >= @log_flush_max ->
        {:ok, flush_logs(state)}

      state.log_flush_pending ->
        {:ok, state}

      true ->
        Process.send_after(self(), :flush_logs, @log_flush_interval_ms)
        {:ok, %{state | log_flush_pending: true}}
    end
  end

  # :state frames drive the Session (which owns transitions + wall-clock + finalize).
  # Flush buffered logs first so they land before any finalize reads them.
  defp on_frame(:state, sm, %{job_id: jid} = state) when is_binary(jid) do
    state = flush_logs(state)

    case JobState.from_agent_transition(sm.transition) do
      {:ok, event} ->
        extra = if sm.exit_code != nil, do: [exit_code: sm.exit_code], else: []
        Session.agent_event(jid, {event, extra})

      :error ->
        Logger.warning("unknown agent transition #{inspect(sm.transition)}")
    end

    {:ok, state}
  end

  # :bye ends the session — flush the tail before stopping.
  defp on_frame(:bye, msg, %{job_id: jid, instance_id: inst} = state) when is_binary(jid) do
    state = flush_logs(state)
    # A short span (the handshake span is long closed by now) marks a GRACEFUL
    # agent shutdown — the positive signal that distinguishes a clean finish from
    # a silent never-connect / dropped socket.
    Tracer.with_span "agent.termination", %{
      attributes: %{
        "agent.reason" => "graceful",
        "agent.instance_id" => inst,
        "harmont.job.id" => jid
      }
    } do
      :ok = Bridge.apply_frame(jid, {:bye, msg}, inst)
    end

    {:stop, :normal, state}
  end

  # Heartbeats reset the Session's liveness watchdog (proof the agent is alive)
  # AND persist last_heartbeat_at via the Bridge (the durable backstop reads it).
  defp on_frame(:heartbeat, msg, %{job_id: jid, instance_id: inst} = state) when is_binary(jid) do
    :ok = Session.heartbeat(jid)
    :ok = Bridge.apply_frame(jid, {:heartbeat, msg}, inst)
    {:ok, state}
  end

  defp on_frame(tag, msg, %{job_id: jid, instance_id: inst} = state) when is_binary(jid) do
    :ok = Bridge.apply_frame(jid, {tag, msg}, inst)
    {:ok, state}
  end

  # Frames before Hello: ignore
  defp on_frame(_tag, _msg, state), do: {:ok, state}

  # PubSub cancel arrives as a process message -> push a CancelMsg to the agent.
  @impl true
  def handle_info(:cancel, state),
    do: {:push, {:binary, Protocol.encode_cancel("build canceled")}, state}

  def handle_info(:flush_logs, state),
    do: {:ok, %{flush_logs(state) | log_flush_pending: false}}

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    _ = flush_logs(state)
    :ok
  end

  # Batch-persist buffered chunks (oldest first). A crash before flush loses only
  # the buffer; the agent replays from `max_seq` on reconnect, so nothing is lost.
  defp flush_logs(%{log_buf: []} = state), do: state

  defp flush_logs(%{job_id: jid, log_buf: buf} = state) when is_binary(jid) do
    :ok = Store.append_batch(jid, Enum.reverse(buf))
    %{state | log_buf: [], log_buf_len: 0}
  end

  defp flush_logs(state), do: state

  defp stream_kind(:STDOUT), do: 0
  defp stream_kind(:STDERR), do: 1
  defp stream_kind(:META), do: 2
  defp stream_kind(_), do: 0

  defp check_proto(v) when v >= @proto_version, do: :ok
  defp check_proto(_), do: {:error, :PROTO_INCOMPATIBLE}

  defp authorize(hello, token) do
    build = Harmont.Repo.get_by(Build, external_build_id: hello.build_id)

    cond do
      is_nil(build) ->
        {:error, :JOB_NOT_FOUND}

      not token_matches?(build.runner_token_hash, token) ->
        {:error, :UNAUTHORIZED}

      true ->
        case Harmont.Repo.one(
               from(j in Job, where: j.id == ^hello.job_id and j.build_id == ^build.id)
             ) do
          nil -> {:error, :JOB_NOT_FOUND}
          job -> {:ok, build, job}
        end
    end
  end

  # constant-time compare of the stored sha256 against the presented token's hash
  defp token_matches?(nil, _token), do: false
  defp token_matches?(_hash, nil), do: false

  defp token_matches?(hash, token) when is_binary(hash) do
    :crypto.hash_equals(hash, :crypto.hash(:sha256, token))
  end

  # The in-VM agent fetches + extracts this into /workspace before running the
  # job command (agent/src/source.rs), authenticating with its runner token.
  # Materialize persists the per-build internal source endpoint on
  # build.source_url; surface it (the build is already loaded by authorize/2).
  # Empty string only if the build has no source (the agent then runs against an
  # empty workspace, as before).
  defp build_source_url(%Build{source_url: url}) when is_binary(url) and url != "", do: url
  defp build_source_url(_build), do: ""
end
