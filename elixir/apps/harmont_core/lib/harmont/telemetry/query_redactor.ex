defmodule Harmont.Telemetry.QueryRedactor do
  @moduledoc """
  An OpenTelemetry span processor that scrubs secrets out of the `url.query`
  span attribute before spans are handed to the real exporting processor.

  ## Why this exists

  The SSE log stream authenticates with a build-scoped HMAC in the URL query
  (`GET /v0/jobs/:id/logs?token=<hmac>`) because browser `EventSource` cannot
  set request headers. `opentelemetry_bandit` records the raw query string as
  the `url.query` attribute on every HTTP span, and `config/runtime.exs` exports
  traces to Honeycomb in prod — so without scrubbing, every log-stream connect
  (and every `EventSource` reconnect) would write a live, read-granting token
  into the trace backend.

  ## Why a wrapping span processor (not bandit config, not dropping the attr)

  `opentelemetry_bandit` exposes no option to sanitize or disable query capture,
  and dropping `url.query` outright would blind us during debugging. So we redact
  in the OTel pipeline itself, defensively for *every* route — not just the logs
  endpoint — by rewriting `token=<...>` (and other common secret-ish params) to
  `<param>=REDACTED` while leaving the rest of the query intact.

  The OTel Erlang SDK runs `on_end/2` for each configured processor over the
  *same* immutable span (`otel_tracer_server:on_end/1` folds returning only a
  boolean), so two sibling processors cannot transform what the next one sees.
  The robust pattern is therefore a single *composite* processor: this module
  wraps the real `:otel_batch_processor`, rewrites the span's attributes in
  `on_end/2`, then delegates the redacted span to the wrapped processor. It is
  wired as the sole `:processors` entry, so it sits on the prod export path.

  The actual scrub logic lives in `redact_query/1`, a pure function, so it is
  unit-testable without standing up the OTel pipeline.
  """

  @behaviour :otel_span_processor

  alias Harmont.Telemetry.SpanFilter

  require Record

  # The #span{} record (and its `attributes` field) is defined by the OTel SDK.
  # Extract it at compile time so we can read/replace the attributes opaquely.
  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  # The OTel semantic-convention key for the URL query string.
  @url_query_key :"url.query"

  # Query parameters whose values must never reach the trace backend. Matched
  # case-insensitively against the part before `=`.
  @secret_params ~w(token access_token refresh_token api_key apikey key secret password passwd pwd signature sig auth authorization session)

  @redaction "REDACTED"

  @doc false
  @impl :otel_span_processor
  def processor_init(_pid, config) do
    config
  end

  @doc false
  @impl :otel_span_processor
  def on_start(ctx, span, config) do
    :otel_batch_processor.on_start(ctx, span, wrapped(config))
  end

  @doc false
  @impl :otel_span_processor
  def on_end(span, config) do
    if drop_span?(span) do
      # Noise: swallow it. Returning true tells the SDK's on_end fold the span
      # was handled, while never enqueuing it onto the OTLP export path.
      true
    else
      :otel_batch_processor.on_end(redact_span(span), wrapped(config))
    end
  end

  # Reads the fields the SpanFilter predicate needs out of the immutable #span{}
  # record. A malformed span must never break export, so on any error we keep the
  # span (return false = do not drop).
  defp drop_span?(span_record) do
    name = span(span_record, :name)
    parent_span_id = span(span_record, :parent_span_id)
    attributes = :otel_attributes.map(span(span_record, :attributes))
    SpanFilter.drop?(name, parent_span_id, attributes)
  rescue
    _ -> false
  end

  @doc false
  @impl :otel_span_processor
  def force_flush(config) do
    :otel_batch_processor.force_flush(wrapped(config))
  end

  @doc """
  Starts the wrapped batch processor and stashes its config under
  `:wrapped_config`, returning the merged config the SDK threads back into
  every `on_*` callback. Mirrors `:otel_batch_processor.start_link/1`'s
  `{:ok, pid, config}` contract.
  """
  @spec start_link(%{:name => atom() | charlist()}) ::
          {:ok, pid(), %{:name => atom() | charlist(), :wrapped_config => map()}}
  def start_link(config) do
    {:ok, pid, wrapped_config} = :otel_batch_processor.start_link(config)
    {:ok, pid, Map.put(config, :wrapped_config, wrapped_config)}
  end

  # The batch processor needs the config it returned from start_link (it carries
  # the registered name); fall back to the raw config defensively.
  defp wrapped(%{wrapped_config: wrapped}), do: wrapped
  defp wrapped(config), do: config

  defp redact_span(span_record) do
    attrs = span(span_record, :attributes)

    case :otel_attributes.map(attrs) do
      %{@url_query_key => query} when is_binary(query) ->
        scrubbed = redact_query(query)

        if scrubbed == query do
          span_record
        else
          new_attrs = :otel_attributes.set(@url_query_key, scrubbed, attrs)
          span(span_record, attributes: new_attrs)
        end

      _ ->
        span_record
    end
  rescue
    # Never let a malformed span take down the export pipeline; ship it as-is.
    _ -> span_record
  end

  @doc """
  Redacts secret values out of a URL query string, preserving structure.

  Each `&`-separated pair whose key (case-insensitively) names a secret has its
  value replaced with `REDACTED`. Non-secret params and the rest of the query
  are left untouched. A query with no secret params is returned unchanged.

  ## Examples

      iex> Harmont.Telemetry.QueryRedactor.redact_query("token=abc")
      "token=REDACTED"

      iex> Harmont.Telemetry.QueryRedactor.redact_query("foo=1&token=abc&bar=2")
      "foo=1&token=REDACTED&bar=2"

      iex> Harmont.Telemetry.QueryRedactor.redact_query("page=3")
      "page=3"
  """
  @spec redact_query(String.t()) :: String.t()
  def redact_query(query) when is_binary(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &redact_pair/1)
  end

  defp redact_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if secret_key?(key), do: key <> "=" <> @redaction, else: pair

      _ ->
        pair
    end
  end

  defp secret_key?(key) do
    String.downcase(key) in @secret_params
  end
end
