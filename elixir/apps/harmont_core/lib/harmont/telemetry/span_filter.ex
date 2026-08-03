defmodule Harmont.Telemetry.SpanFilter do
  @moduledoc """
  Pure predicate that decides whether an OpenTelemetry span is export-worthy or
  background noise. Wired into `Harmont.Telemetry.QueryRedactor.on_end/2`, which
  swallows any span this module flags so it never reaches the OTLP exporter.

  ## Why this exists

  The `harmont` backend instruments every Ecto query (`opentelemetry_ecto`),
  every HTTP request (`opentelemetry_bandit`), and every Oban job/plugin tick
  (`opentelemetry_oban`). With no sampler configured, that floods Honeycomb with
  ~1.8M spans/day, ~97% of which are background chatter: Oban Pro pollers hitting
  Postgres, orphan (parentless) DB query spans, GCP load-balancer `/healthz`
  probes, and Oban plugin ticks. None of it is attached to a real request or job
  trace, so none of it has debugging value on its own.

  ## What is dropped (see `drop?/3`)

  A span is dropped iff any rule matches:

    1. Health check  — `url.path == "/healthz"` (GCP LB probes).
    2. Oban infra    — name starts with `"harmont_core.repo.query:oban_"`
                       (oban_jobs/producers/peers/crons/workflows/queues polling).
    3. Orphan Ecto   — an Ecto query span (`"harmont_core.repo.query"...`) that is
                       a trace root, i.e. issued outside any request/job context.
                       Queries that hang under a real trace are KEPT.
    4. Oban plugin   — name starts with `"Elixir.Oban."` and ends with `" process"`
                       (Stager/Lifeline/DynamicPruner/DynamicCron ticks). Real job
                       spans are named `"process <queue>"` and are NOT matched.

  Everything else — real API routes, `process <queue>` job spans, `job.run`,
  `exception`, child DB queries under real traces, Freestyle bridge spans — is
  kept. Dropping never orphans a kept child: every dropped span is either a leaf
  (DB query, health probe) or a plugin-tick root whose only children are
  `oban_*` leaves that rule 2 drops alongside it.
  """

  # opentelemetry_ecto names query spans `<telemetry_prefix>.query[:<source>]`.
  @ecto_query_prefix "harmont_core.repo.query"
  @oban_query_prefix "harmont_core.repo.query:oban_"

  # opentelemetry_oban names plugin spans `<Plugin module> process`; job spans
  # are `process <queue>`, so the module prefix distinguishes them.
  @oban_plugin_prefix "Elixir.Oban."
  @oban_plugin_suffix " process"

  # opentelemetry_bandit records the request path under this attribute key.
  @url_path_key :"url.path"
  @healthz_path "/healthz"

  @doc """
  Returns `true` when a span is background noise that should not be exported.

  Arguments are already extracted from the `#span{}` record by the caller so this
  function stays pure and unit-testable:

    * `name` — the span name (string or atom).
    * `parent_span_id` — the span's parent id; `:undefined` or `nil` means the
      span is a trace root.
    * `attributes` — a plain map of the span's attributes (atom keys).
  """
  @spec drop?(String.t() | atom(), term(), map()) :: boolean()
  def drop?(name, parent_span_id, attributes) do
    name = to_string(name)

    healthz?(attributes) or
      oban_infra_query?(name) or
      orphan_ecto_query?(name, parent_span_id) or
      oban_plugin_span?(name)
  end

  defp healthz?(attributes), do: Map.get(attributes, @url_path_key) == @healthz_path

  defp oban_infra_query?(name), do: String.starts_with?(name, @oban_query_prefix)

  defp orphan_ecto_query?(name, parent_span_id),
    do: String.starts_with?(name, @ecto_query_prefix) and root?(parent_span_id)

  defp oban_plugin_span?(name),
    do:
      String.starts_with?(name, @oban_plugin_prefix) and
        String.ends_with?(name, @oban_plugin_suffix)

  defp root?(parent_span_id), do: parent_span_id in [:undefined, nil]
end
