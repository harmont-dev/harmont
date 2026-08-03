defmodule HarmontWeb.LogStream do
  @moduledoc """
  Server-Sent Events (SSE) transport for live job logs.

  Exposes `GET /v0/jobs/:job_id/logs?token=<hmac>` as `text/event-stream`,
  replacing the former Phoenix `LogChannel`. Any HTTP client (browser
  `EventSource`, `hm` CLI, third-party) can consume live logs.

  Wire shape:

    * one `event: history` frame (no `id:`) carrying `{"chunks":[...]}` — a
      replay from the resume floor (full history, or the post-cursor delta
      when the client sent `Last-Event-ID`),
    * then per-chunk `event: chunk` frames each carrying `id: <seq>`,
    * finally, when the job reaches a terminal state, one `event: done` frame
      (no `id:`) signalling end-of-log, after which the stream closes.

  Each `history`/`chunk` frame carries `seq`, so clients fold by sequence
  number and a resume `history` appends (not overwrites) — reconnects never
  wipe already-shown logs. The `done` event lets a client distinguish normal
  completion from a transport failure.

  Auth (`LogToken`) and the `Logs.PubSub`/`Logs.Store` replay-and-tail logic
  are unchanged — this only shapes the transport at the edge.
  """

  import Plug.Conn
  alias Harmont.Logs.{Authz, PubSub, Store}
  alias HarmontWeb.LogToken

  # Heartbeat comment cadence: keeps the connection warm through proxies and
  # lets us detect a vanished peer (chunk/2 returns {:error, :closed}).
  @heartbeat_ms 15_000

  # Job FSM states past which no more log chunks will ever arrive. Mirrors the
  # terminal set in Harmont.Builds.Job; when a streamed job reaches one of
  # these we send a `done` event and close.
  @terminal_states ~w(passed failed skipped canceled timed_out)

  @doc """
  Entry point invoked by the `:log_stream` endpoint plug for
  `GET /v0/jobs/:job_id/logs`.

  Verifies the build-scoped HMAC token, checks the job belongs to that build,
  then opens a `text/event-stream` chunked response: a `history` replay
  followed by a live tail of `chunk` events. Auth failures return a precise
  JSON error (Stripe/Rust doctrine), NOT an event-stream.
  """
  @spec call(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def call(conn, job_id) do
    conn = fetch_query_params(conn)
    token = conn.query_params["token"]

    case LogToken.verify(token || "", LogToken.secret()) do
      {:ok, build_uuid} ->
        if Authz.authorized?(job_id, build_uuid) do
          start_stream(conn, job_id)
        else
          error(
            conn,
            403,
            "log_stream_forbidden",
            "This log token is not scoped to job #{job_id}. The token's build does not own this job."
          )
        end

      {:error, reason} ->
        error(
          conn,
          401,
          "log_stream_unauthorized",
          unauthorized_message(token, reason)
        )
    end
  end

  defp unauthorized_message(nil, _reason),
    do:
      "Missing log token. Pass the build-scoped HMAC as the `token` query parameter: GET /v0/jobs/:job_id/logs?token=<token>."

  defp unauthorized_message("", _reason), do: unauthorized_message(nil, :malformed)

  defp unauthorized_message(_token, reason),
    do:
      "Log token rejected (#{reason}). Mint a fresh build-scoped token from the API and retry; tokens expire with the build's lease."

  defp error(conn, status, code, message) do
    body = Jason.encode!(%{code: code, message: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # Subscribe BEFORE replaying history so no live chunk is missed in the gap
  # between Store.list/2 and the receive loop.
  defp start_stream(conn, job_id) do
    :ok = Phoenix.PubSub.subscribe(Harmont.PubSub, PubSub.topic(job_id))

    conn =
      conn
      |> maybe_allow_origin()
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # No cursor → replay the full history from seq 0. With a cursor
    # `Last-Event-ID: N` the client already has through seq N, so the replay
    # floor is N+1 (Store.list/2 is inclusive of its `since_seq` argument).
    {floor, hwm0} =
      case resume_cursor(conn) do
        nil -> {0, -1}
        last_seen -> {last_seen + 1, last_seen}
      end

    chunks = Store.list(job_id, floor)

    history = [
      "event: history\ndata: ",
      Jason.encode_to_iodata!(%{chunks: Enum.map(chunks, &render/1)}),
      "\n\n"
    ]

    hwm = chunks |> Enum.map(& &1.seq) |> Enum.max(fn -> hwm0 end)

    case chunk(conn, history) do
      {:ok, conn} -> stream_loop(conn, job_id, hwm)
      {:error, :closed} -> done(conn, job_id)
    end
  end

  # Echo a same-origin allow header when the request Origin is in the
  # configured CORS allowlist (a simple GET — no preflight, token is a query
  # param and there are no custom request headers).
  defp maybe_allow_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] ->
        if origin_allowed?(origin),
          do: put_resp_header(conn, "access-control-allow-origin", origin),
          else: conn

      [] ->
        conn
    end
  end

  defp origin_allowed?(origin) do
    allowed =
      Application.get_env(:harmont_web, HarmontWeb.Endpoint)[
        :log_stream_allowed_origins
      ] || ["//localhost:8765"]

    %{scheme: scheme, host: host, port: port} = URI.parse(origin)

    Enum.any?(allowed, fn origin_str ->
      %{scheme: a_scheme, host: a_host, port: a_port} = URI.parse(origin_str)
      compare(scheme, a_scheme) and compare(host, a_host) and compare(port, a_port)
    end)
  end

  # nil in an allowlist entry means "wildcard" (matches any value).
  defp compare(_actual, nil), do: true
  defp compare(actual, expected), do: actual == expected

  defp stream_loop(conn, job_id, hwm) do
    receive do
      {:log_chunk, %{seq: seq} = c} when seq > hwm ->
        case chunk(conn, sse_event("chunk", c)) do
          {:ok, conn} -> stream_loop(conn, job_id, seq)
          {:error, :closed} -> done(conn, job_id)
        end

      {:log_chunk, _dup} ->
        # Already covered by the replayed history — drop the duplicate.
        stream_loop(conn, job_id, hwm)
    after
      @heartbeat_ms ->
        # On each idle tick, send a heartbeat comment AND check whether the job
        # has reached a terminal state. A terminal job emits no more chunks, so
        # we send an explicit `done` event and close: the client distinguishes
        # normal end-of-log from a transport failure (no false "stream closed"
        # error on success). The check is one indexed row read every 15s.
        case chunk(conn, ":\n\n") do
          {:ok, conn} ->
            if job_terminal?(job_id),
              do: finish(conn, job_id),
              else: stream_loop(conn, job_id, hwm)

          {:error, :closed} ->
            done(conn, job_id)
        end
    end
  end

  # Job in a terminal FSM state → its log is complete. A missing job (deleted)
  # also counts as "no more logs coming". DB errors are treated as non-terminal
  # so a transient blip keeps the stream alive rather than ending it early.
  defp job_terminal?(job_id) do
    case Harmont.Repo.get(Harmont.Builds.Job, job_id) do
      %Harmont.Builds.Job{state: state} -> state in @terminal_states
      nil -> true
    end
  rescue
    _ -> false
  end

  # Send a terminal `done` event, then unsubscribe and return the conn. The
  # `done` frame carries no `id:`, so a client reconnect won't try to resume
  # past it.
  defp finish(conn, job_id) do
    case chunk(conn, "event: done\ndata: {}\n\n") do
      {:ok, conn} -> done(conn, job_id)
      {:error, :closed} -> done(conn, job_id)
    end
  end

  # Client gone (or stream finished): unsubscribe and return the conn cleanly
  # (no crash log).
  defp done(conn, job_id) do
    Phoenix.PubSub.unsubscribe(Harmont.PubSub, PubSub.topic(job_id))
    conn
  end

  @doc """
  Frames a single log chunk as one SSE event:
  `id: <seq>\\nevent: <name>\\ndata: <json>\\n\\n`.
  """
  @spec sse_event(String.t(), map()) :: iolist()
  def sse_event(name, %{seq: seq} = chunk) do
    [
      "id: ",
      Integer.to_string(seq),
      "\nevent: ",
      name,
      "\ndata: ",
      Jason.encode_to_iodata!(render(chunk)),
      "\n\n"
    ]
  end

  # The client's last-received seq, or nil when no resume cursor is present.
  # Distinguishing "absent" from "0" matters: absent ⇒ replay from seq 0;
  # `Last-Event-ID: 0` ⇒ replay from seq 1.
  @spec resume_cursor(Plug.Conn.t()) :: non_neg_integer() | nil
  defp resume_cursor(conn) do
    header =
      case Plug.Conn.get_req_header(conn, "last-event-id") do
        [v | _] -> v
        [] -> nil
      end

    parse_seq(header) || parse_seq(query_param(conn))
  end

  defp query_param(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}}), do: nil
  defp query_param(%Plug.Conn{query_params: params}), do: params["last_event_id"]

  defp parse_seq(nil), do: nil

  defp parse_seq(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      {n, ""} when n < 0 -> 0
      _ -> nil
    end
  end

  @doc """
  Renders a stored chunk into the JSON shape clients consume.
  Mirrors the former `LogChannel.render/1`.
  """
  @spec render(map()) :: map()
  def render(c),
    do: %{
      seq: c.seq,
      stream_kind: c[:stream_kind] || 0,
      content: to_string(c.content),
      ts: c[:ts_unix_ns]
    }
end
