defmodule Harmont.GhApp.CheckOutputTest do
  use ExUnit.Case, async: true

  alias Harmont.Apps.{BuildState, StepSummary}
  alias Harmont.GhApp.CheckOutput

  defp check do
    %{org_slug: "marko-harmont-dev", pipeline_slug: "harmont-cli-ci", build_number: 121}
  end

  defp steps do
    [
      %StepSummary{
        key: "base",
        label: "base",
        state: "passed",
        started_at: ~U[2026-06-12 00:00:00Z],
        finished_at: ~U[2026-06-12 00:00:04Z]
      },
      %StepSummary{
        key: "clippy",
        label: "clippy",
        state: "running",
        started_at: ~U[2026-06-12 00:00:04Z]
      },
      %StepSummary{
        key: "pytest",
        label: ":python: test",
        state: "failed",
        exit_code: 1,
        error_message: "1 test failed",
        started_at: ~U[2026-06-12 00:00:04Z],
        finished_at: ~U[2026-06-12 00:00:16Z]
      }
    ]
  end

  test "returns nil when there are no steps" do
    assert CheckOutput.render(
             %BuildState{phase: :queued, summary: []},
             check(),
             "https://app.harmont.dev"
           ) == nil
  end

  test "title summarizes counts by bucket" do
    out =
      CheckOutput.render(
        %BuildState{phase: :running, summary: steps()},
        check(),
        "https://app.harmont.dev"
      )

    assert out.title == "1 passed · 1 failed · 1 running"
  end

  test "summary is a markdown step table with status + duration" do
    out =
      CheckOutput.render(
        %BuildState{phase: :running, summary: steps()},
        check(),
        "https://app.harmont.dev"
      )

    assert out.summary =~ "| Step | Status | Time |"
    assert out.summary =~ "base"
    assert out.summary =~ "✅"
    assert out.summary =~ "4s"
    assert out.summary =~ "🔄"
  end

  test "text lists failing steps with exit code and a dashboard link" do
    out =
      CheckOutput.render(
        %BuildState{phase: :failed, summary: steps()},
        check(),
        "https://app.harmont.dev"
      )

    assert out.text =~ "pytest"
    assert out.text =~ "exit 1"
    assert out.text =~ "1 test failed"

    assert out.text =~
             "https://app.harmont.dev/marko-harmont-dev/pipelines/harmont-cli-ci/builds/121"
  end

  test "omits the link when web_base is blank" do
    out = CheckOutput.render(%BuildState{phase: :failed, summary: steps()}, check(), "")
    refute out.text =~ "http"
  end

  test "queued/0 is a static starting-output map" do
    out = CheckOutput.queued()
    assert out.title == "Queued"
    assert out.summary =~ "waiting"
  end

  test "truncates an over-cap output on a valid UTF-8 boundary" do
    # ~66KB of 3-byte UTF-8 characters in a label forces summary truncation.
    big_label = String.duplicate("あ", 22_000)
    steps = [%StepSummary{key: "x", label: big_label, state: "passed"}]

    out =
      CheckOutput.render(
        %BuildState{phase: :running, summary: steps},
        check(),
        "https://app.harmont.dev"
      )

    assert String.valid?(out.summary)
    assert byte_size(out.summary) <= 65_000 + byte_size("\n…(truncated)")
    assert out.summary =~ "(truncated)"
  end

  test "a soft-failed step shows ⚠️ in the table but is excluded from failures" do
    steps = [
      %StepSummary{
        key: "flaky",
        label: "flaky",
        state: "failed",
        soft_failed: true,
        exit_code: 1,
        error_message: "flaked"
      }
    ]

    out =
      CheckOutput.render(
        %BuildState{phase: :passed, summary: steps},
        check(),
        "https://app.harmont.dev"
      )

    assert out.summary =~ "⚠️"
    refute out.text =~ "flaky"
    refute out.text =~ "### Failures"
  end
end
