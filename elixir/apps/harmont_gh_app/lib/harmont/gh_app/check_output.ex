defmodule Harmont.GhApp.CheckOutput do
  @moduledoc """
  Renders a neutral `Harmont.Apps.BuildState` (phase + per-step summary) into a
  GitHub Check Run `output` map (`%{title, summary, text}`). Pure: no DB, no
  network. Returns `nil` when there are no steps yet, so the caller omits the
  `output` field and GitHub keeps the prior body. `summary`/`text` are markdown,
  each truncated to 65000 bytes (a safe margin under GitHub's 65535-char
  per-field limit), always on a valid UTF-8 boundary.
  """
  alias Harmont.Apps.BuildState
  alias Harmont.Apps.StepSummary

  @field_cap 65_000

  @spec queued() :: map()
  def queued do
    %{
      title: "Queued",
      summary:
        "Build queued — waiting for steps to start. This check updates as the pipeline runs."
    }
  end

  @spec render(BuildState.t(), map(), String.t()) :: map() | nil
  def render(%BuildState{summary: []}, _check, _web_base), do: nil

  def render(%BuildState{summary: steps}, check, web_base) do
    %{
      title: title(steps),
      summary: cap(table(steps)),
      text: cap(failures(steps, check, web_base))
    }
  end

  # --- title: "N passed · N failed · N running" (only non-zero buckets) ---

  defp title(steps) do
    counts = Enum.frequencies_by(steps, &bucket/1)

    [
      {:passed, "passed"},
      {:failed, "failed"},
      {:running, "running"},
      {:queued, "queued"},
      {:skipped, "skipped"},
      {:canceled, "canceled"}
    ]
    |> Enum.map(fn {b, word} -> {Map.get(counts, b, 0), word} end)
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> Enum.map(fn {n, word} -> "#{n} #{word}" end)
    |> case do
      [] -> "No steps"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp bucket(%StepSummary{state: s}) when s in ~w(passed), do: :passed
  defp bucket(%StepSummary{state: s}) when s in ~w(failed timed_out), do: :failed
  defp bucket(%StepSummary{state: s}) when s in ~w(running), do: :running
  defp bucket(%StepSummary{state: s}) when s in ~w(skipped), do: :skipped
  defp bucket(%StepSummary{state: s}) when s in ~w(canceling canceled), do: :canceled
  defp bucket(%StepSummary{}), do: :queued

  # --- summary: markdown step table ---

  defp table(steps) do
    header = "| Step | Status | Time |\n|---|---|---|"

    rows =
      Enum.map_join(steps, "\n", fn step ->
        "| #{escape(step.label || step.key)} | #{emoji(step)} | #{duration(step)} |"
      end)

    header <> "\n" <> rows
  end

  defp emoji(%StepSummary{state: "passed"}), do: "✅"
  defp emoji(%StepSummary{state: s, soft_failed: true}) when s in ~w(failed timed_out), do: "⚠️"
  defp emoji(%StepSummary{state: s}) when s in ~w(failed), do: "❌"
  defp emoji(%StepSummary{state: "timed_out"}), do: "⏰"
  defp emoji(%StepSummary{state: "running"}), do: "🔄"
  defp emoji(%StepSummary{state: "skipped"}), do: "⏭️"
  defp emoji(%StepSummary{state: s}) when s in ~w(canceling canceled), do: "🚫"
  defp emoji(%StepSummary{}), do: "⏳"

  defp duration(%StepSummary{started_at: %DateTime{} = a, finished_at: %DateTime{} = b}) do
    secs = DateTime.diff(b, a, :second)
    "#{secs}s"
  end

  defp duration(%StepSummary{state: "running"}), do: "running…"
  defp duration(%StepSummary{}), do: "—"

  # --- text: failing-step details + dashboard link ---

  defp failures(steps, check, web_base) do
    failed = Enum.filter(steps, fn s -> bucket(s) == :failed and s.soft_failed != true end)

    details =
      case failed do
        [] -> ""
        list -> "### Failures\n\n" <> Enum.map_join(list, "\n", &failure_line/1)
      end

    [details, link(check, web_base)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp failure_line(s) do
    code = if s.exit_code, do: " (exit #{s.exit_code})", else: ""
    msg = if s.error_message, do: " — #{escape(s.error_message)}", else: ""
    "- **#{step_display(s)}**#{code}#{msg}"
  end

  defp link(_check, ""), do: ""
  defp link(_check, nil), do: ""

  defp link(check, web_base) do
    base = String.trim_trailing(web_base, "/")

    "→ [View full logs on the dashboard](#{base}/#{check.org_slug}/pipelines/#{check.pipeline_slug}/builds/#{check.build_number})"
  end

  # --- helpers ---

  # Returns "label (key)" when label differs from key, otherwise just the key.
  # This ensures the step key always appears in failure output for programmatic
  # matching (e.g. "pytest" even when label is ":python: test").
  defp step_display(%StepSummary{key: key, label: nil}), do: escape(key)
  defp step_display(%StepSummary{key: key, label: key}), do: escape(key)

  defp step_display(%StepSummary{key: key, label: label}),
    do: "#{escape(label)} (#{escape(key)})"

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp cap(text) when byte_size(text) <= @field_cap, do: text

  defp cap(text) do
    valid_prefix(binary_part(text, 0, @field_cap)) <> "\n…(truncated)"
  end

  # Drop up to 3 trailing bytes that form an incomplete UTF-8 sequence, so the
  # truncated prefix is always valid UTF-8 (GitHub rejects invalid bytes with 422).
  defp valid_prefix(<<>>), do: <<>>

  defp valid_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
