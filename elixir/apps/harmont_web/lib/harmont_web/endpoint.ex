defmodule HarmontWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :harmont_web

  alias Harmont.Apps.Webhook

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_harmont_key",
    signing_salt: "P5Cv+FOr",
    same_site: "Lax"
  ]

  # LiveView socket the Oban Web dashboard (mounted by HarmontWeb.OpsRouter at
  # /ops/oban) connects over. This is the only LiveView surface in this otherwise
  # JSON/WebSocket app; the dashboard sits behind HTTP Basic auth in the router.
  socket("/live", Phoenix.LiveView.Socket)

  # Must run BEFORE Plug.Telemetry (opentelemetry_phoenix extraction) and the
  # opentelemetry_bandit span — strips GCP-injected trace context at the edge.
  plug(HarmontWeb.StripTraceContext)
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {HarmontWeb.CacheBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(:healthz)
  plug(:agent_upgrade)
  plug(:log_stream)
  plug(:webhook)
  plug(:github_internal)
  plug(:ops_dashboard)

  # CORS for the cross-origin SPA (app.harmont.dev → api.harmont.dev). Runs
  # AFTER the special path-dispatch plugs (so it never touches the agent
  # WebSocket upgrade, the SSE log stream — which sets its own allow header —
  # or the GitHub webhook) and BEFORE the REST router, so it answers the
  # browser's preflight OPTIONS for `/api/v0/*` and stamps
  # `Access-Control-Allow-Origin` on the API's responses. Origins are checked
  # at request time against the runtime-configured allowlist.
  plug(Corsica,
    origins: {HarmontWeb.Cors, :allowed_origin?, []},
    allow_headers: ["authorization", "content-type"],
    allow_methods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
    allow_credentials: true,
    max_age: 600
  )

  # The user-facing REST API (harmont_api). Mounted AFTER the special
  # path-dispatch plugs above so those keep matching their exact paths first
  # (each falls through to the next plug for non-matching requests). The API
  # owns `/api/v0/*`; the gh_app internal endpoints live under
  # `/api/installations*` (a different prefix), so there is no collision.
  plug(HarmontApi.Router)

  # Liveness/readiness probe for the GCE health checks (MIG auto-heal + the
  # public LB backend). Lives before agent_upgrade/log_stream so it never
  # collides with those long-lived endpoints.
  #
  # While `Harmont.Drain` is draining (SIGTERM received) we return 503 so the LB
  # marks this backend unhealthy and stops routing new requests here, giving us
  # a clean window before `System.stop/0`.
  def healthz(%Plug.Conn{request_path: "/healthz"} = conn, _opts) do
    {status, body} =
      if Harmont.Drain.draining?() do
        {503, "draining"}
      else
        {200, "ok"}
      end

    conn
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  def healthz(conn, _opts), do: conn

  def agent_upgrade(%Plug.Conn{request_path: "/v0/agent/connect"} = conn, _opts) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> t | _] -> t
        _ -> nil
      end

    # WebSocket IDLE timeout: the connection is closed if no frame is received
    # for this long. The agent heartbeats every 5s, but under a flood of compile
    # output its send loop can backpressure (the backend persists each log chunk),
    # starving the heartbeat past a tight 60s window — which closed the WS
    # mid-build, forcing the agent to reconnect-and-replay and eventually abort a
    # long job. 10 minutes leaves ample margin over any realistic log-send stall
    # while still reaping a genuinely dead agent in bounded time.
    conn
    |> WebSockAdapter.upgrade(HarmontWeb.AgentSocket, [token: token], timeout: 600_000)
    |> Plug.Conn.halt()
  end

  def agent_upgrade(conn, _opts), do: conn

  # Long-lived SSE log stream. Lives as an explicit endpoint plug (mirroring
  # agent_upgrade) rather than a Router controller because send_chunked + a
  # receive loop belongs outside the Router pipeline.
  def log_stream(
        %Plug.Conn{method: "GET", path_info: ["v0", "jobs", job_id, "logs"]} = conn,
        _opts
      ) do
    conn
    |> HarmontWeb.LogStream.call(job_id)
    |> Plug.Conn.halt()
  end

  def log_stream(conn, _opts), do: conn

  # Provider-agnostic webhook receiver for `POST /webhooks/:provider`. An
  # explicit endpoint plug (mirroring agent_upgrade/log_stream) so the raw-body
  # signature check and handler dispatch live outside any Router pipeline. The
  # CacheBodyReader (wired into Plug.Parsers above) has already stashed the exact
  # signed bytes for every `/webhooks/...` path under conn.assigns.raw_body.
  # Harmont.Apps.Webhook resolves the provider impl + secret from `:harmont_apps`
  # app env (GitHub is registered there at boot) and enqueues the delivery for the
  # single Harmont.Apps.Engine.handle/3 dispatch.
  def webhook(%Plug.Conn{method: "POST"} = conn, _opts) do
    case conn.path_info do
      ["webhooks", provider] ->
        conn
        |> Plug.Conn.assign(:webhook_provider, provider)
        |> Webhook.call([])

      _ ->
        conn
    end
  end

  def webhook(conn, _opts), do: conn

  # Internal repo/file proxy endpoints that harmont-api calls (it holds no
  # GitHub App private key). An explicit endpoint plug, mirroring the others, so
  # the Bearer auth + installation-token + GitHub/Harmont.Repo dispatch live
  # outside any Router pipeline. Three routes, all anchored under
  # ["api", "installations" | _] so they never swallow /v0/..., /healthz, or
  # /webhooks/github:
  #
  #   * ["api", "installations"]                                    → list
  #   * ["api", "installations", id, "repos"]                       → repos list
  #   * ["api", "installations", id, "repos", owner, repo, "file"]  → file fetch
  #
  # GithubInternal.call/1 disambiguates on path_info; this plug only gates which
  # requests reach it. The bare-list clause is separate from the repos clause so
  # ["api", "installations", id] (no trailing segment) still falls through to
  # the Router rather than being claimed here.
  def github_internal(
        %Plug.Conn{method: "GET", path_info: ["api", "installations"]} = conn,
        _opts
      ) do
    HarmontWeb.GithubInternal.call(conn)
  end

  def github_internal(
        %Plug.Conn{method: "GET", path_info: ["api", "installations", _id, "repos" | _]} = conn,
        _opts
      ) do
    HarmontWeb.GithubInternal.call(conn)
  end

  def github_internal(conn, _opts), do: conn

  # Internal ops dashboard (Oban Web). An explicit path-guarded endpoint plug
  # (mirroring the others) so the LiveView/browser HarmontWeb.OpsRouter only
  # handles `/ops/*` and every other request falls through to HarmontApi.Router
  # below. A Phoenix.Router sends its own 404, so we must NOT mount it as a bare
  # catch-all here; gating on the `ops` path prefix keeps the API/WebSocket
  # dispatch untouched. Auth (HTTP Basic) lives inside the OpsRouter pipeline.
  def ops_dashboard(%Plug.Conn{path_info: ["ops" | _]} = conn, _opts) do
    conn
    |> HarmontWeb.OpsRouter.call(HarmontWeb.OpsRouter.init([]))
    |> Plug.Conn.halt()
  end

  def ops_dashboard(conn, _opts), do: conn
end
