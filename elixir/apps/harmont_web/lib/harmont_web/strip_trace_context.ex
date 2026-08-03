defmodule HarmontWeb.StripTraceContext do
  @moduledoc """
  Drop W3C / Google trace-context headers on every inbound request at the
  external edge, before OpenTelemetry extracts them.

  GCP's HTTPS load balancer / Cloud Run front end injects a `traceparent` (and
  rewrites it on the service-to-service hop). The span it names lives in Google
  Cloud Trace, never Honeycomb, so honoring it parents the request span under an
  invisible "missing root span" on every webhook and public request.

  `hmex`'s HTTP ingress is the external edge (GitHub webhooks on
  `gh.harmont.dev`, the SSE log stream, the agent socket, health checks) plus a
  couple of low-volume internal endpoints the api calls. We strip
  **unconditionally** — the only cost is that the api → `/api/installations/*`
  hop becomes its own Honeycomb root instead of stitching to the api's trace,
  which is an acceptable trade for not carrying route-aware exemption logic.

  Mirrors the api's `Harmont.Telemetry.Wai.stripInboundTraceContext`, but the
  api keeps the internal-route exemption (higher-volume, genuinely-traced
  callers); hmex does not.

  Placement matters: this must be the FIRST endpoint plug so the headers are
  gone before `opentelemetry_phoenix` (reads at `[:phoenix, :endpoint, :start]`,
  fired by `Plug.Telemetry`) and `opentelemetry_bandit` (reads the post-plug
  conn at `[:bandit, :request, :stop]`) extract propagation context.
  """
  @behaviour Plug

  # Lower-case; req_header names are normalized to lower-case by Plug/Bandit.
  @trace_headers ~w(traceparent tracestate x-cloud-trace-context)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{req_headers: headers} = conn, _opts) do
    %{conn | req_headers: Enum.reject(headers, fn {name, _v} -> name in @trace_headers end)}
  end
end
