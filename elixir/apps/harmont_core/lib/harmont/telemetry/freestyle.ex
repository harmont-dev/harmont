defmodule Harmont.Telemetry.Freestyle do
  @moduledoc """
  Bridges the standalone Freestyle client's `[:freestyle, :request, :*]`
  `:telemetry` events to OpenTelemetry spans, so every Freestyle HTTP call (VM
  provision, exec-await, snapshot, …) shows up as a span in the trace next to
  the Ecto/Oban/Phoenix instrumentation.

  The `freestyle` package depends only on `:telemetry` (it ships independently and
  must not pull in OpenTelemetry); this module — living in the app that wires OTel
  — is the bridge. It mirrors `opentelemetry_oban`: `start` pushes a span, `stop`
  /`exception` pop it, all in the SAME process. That holds here because the
  Freestyle client runs each request's start→work→stop synchronously inside
  `Freestyle.Telemetry.span/2`, with no nested or interleaved Freestyle spans on
  the same process, so the per-`tracer_id` span stack `opentelemetry_telemetry`
  stays balanced.

  Why this matters: a provision/exec that times out surfaces as a `:stop` event
  with `result: :error` and (since the enrichment in `Freestyle.Telemetry`) an
  `:error_kind`/`:error_message` of `:transport`/`"timeout"`. Without this bridge
  those events go nowhere and the only trace evidence is the failed Oban job —
  exactly the blind spot that hid the Freestyle provision timeout.
  """
  alias OpenTelemetry.Span

  @tracer_id __MODULE__
  @handler_id "harmont-telemetry-freestyle"

  @events [
    [:freestyle, :request, :start],
    [:freestyle, :request, :stop],
    [:freestyle, :request, :exception]
  ]

  @doc """
  Attach the Freestyle → OpenTelemetry span bridge. Idempotent: a prior handler
  with the same id is detached first, so calling it again (boot, tests) is safe.
  """
  @spec setup() :: :ok
  def setup do
    _ = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), map()) :: :ok
  def handle_event([:freestyle, :request, :start], _measurements, meta, _config) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name(meta),
      meta,
      %{kind: :client, attributes: start_attributes(meta)}
    )

    :ok
  end

  def handle_event([:freestyle, :request, :stop], _measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
    Span.set_attributes(ctx, stop_attributes(meta))

    if Map.get(meta, :result) == :error do
      Span.set_status(ctx, OpenTelemetry.status(:error, error_message(meta)))
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
    :ok
  end

  def handle_event([:freestyle, :request, :exception], _measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    case meta do
      %{reason: reason, stacktrace: stacktrace} ->
        if is_exception(reason), do: Span.record_exception(ctx, reason, stacktrace)
        Span.set_status(ctx, OpenTelemetry.status(:error, reason_text(reason)))

      _ ->
        :ok
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # ── attribute mapping ─────────────────────────────────────────────────

  defp span_name(%{operation: op}) when is_binary(op), do: op
  defp span_name(_), do: "freestyle.request"

  defp start_attributes(meta) do
    %{}
    |> put_if(:"freestyle.operation", Map.get(meta, :operation))
    |> put_if(:"http.request.method", http_method(meta))
    |> put_if(:"url.path", Map.get(meta, :path))
    |> put_if(:"server.address", Map.get(meta, :client))
  end

  defp stop_attributes(meta) do
    %{}
    |> put_if(:"http.response.status_code", Map.get(meta, :status))
    |> put_if(:"freestyle.result", stringify(Map.get(meta, :result)))
    |> put_if(:"freestyle.error_kind", stringify(Map.get(meta, :error_kind)))
    |> put_if(:"freestyle.error_code", Map.get(meta, :error_code))
    |> put_if(:"freestyle.error_message", Map.get(meta, :error_message))
  end

  # The error span-status description: prefer the human message ("timeout"), fall
  # back to the stable code, else empty.
  defp error_message(meta),
    do: Map.get(meta, :error_message) || Map.get(meta, :error_code) || ""

  defp http_method(%{method: method}) when is_atom(method) and not is_nil(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp http_method(%{method: method}) when is_binary(method), do: String.upcase(method)
  defp http_method(_), do: nil

  defp reason_text(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_text(reason), do: inspect(reason)

  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: v

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
