defmodule Harmont.Apps.BuildStateTest do
  use ExUnit.Case, async: true

  alias Harmont.Apps.BuildState

  describe "project/1" do
    test "maps :scheduled to a queued phase with no conclusion" do
      assert BuildState.project(:scheduled) == %BuildState{phase: :queued, conclusion: nil}
    end

    test "maps :running to a running phase with no conclusion" do
      assert BuildState.project(:running) == %BuildState{phase: :running, conclusion: nil}
    end

    test "maps :passed to a terminal passed phase and conclusion" do
      assert BuildState.project(:passed) == %BuildState{phase: :passed, conclusion: :passed}
    end

    test "maps :failed to a terminal failed phase and conclusion" do
      assert BuildState.project(:failed) == %BuildState{phase: :failed, conclusion: :failed}
    end

    test "maps :canceled to a terminal canceled phase and conclusion" do
      assert BuildState.project(:canceled) == %BuildState{phase: :canceled, conclusion: :canceled}
    end
  end

  describe "terminal?/1" do
    test "non-terminal phases are not terminal" do
      refute BuildState.terminal?(%BuildState{phase: :queued})
      refute BuildState.terminal?(%BuildState{phase: :running})
    end

    test "terminal phases are terminal" do
      assert BuildState.terminal?(%BuildState{phase: :passed, conclusion: :passed})
      assert BuildState.terminal?(%BuildState{phase: :failed, conclusion: :failed})
      assert BuildState.terminal?(%BuildState{phase: :canceled, conclusion: :canceled})
      assert BuildState.terminal?(%BuildState{phase: :neutral})
    end

    test "every projected aggregate agrees with its phase classification" do
      assert BuildState.terminal?(BuildState.project(:passed))
      assert BuildState.terminal?(BuildState.project(:failed))
      assert BuildState.terminal?(BuildState.project(:canceled))
      refute BuildState.terminal?(BuildState.project(:scheduled))
      refute BuildState.terminal?(BuildState.project(:running))
    end
  end

  describe "to_db/1" do
    test "maps each phase to its neutral string column value" do
      assert BuildState.to_db(%BuildState{phase: :queued}) == %{state: "queued"}
      assert BuildState.to_db(%BuildState{phase: :running}) == %{state: "running"}

      assert BuildState.to_db(%BuildState{phase: :passed, conclusion: :passed}) == %{
               state: "passed"
             }

      assert BuildState.to_db(%BuildState{phase: :failed, conclusion: :failed}) == %{
               state: "failed"
             }

      assert BuildState.to_db(%BuildState{phase: :canceled, conclusion: :canceled}) == %{
               state: "canceled"
             }

      assert BuildState.to_db(%BuildState{phase: :neutral}) == %{state: "neutral"}
    end

    test "to_db ignores the conclusion (only the phase is persisted as state)" do
      assert BuildState.to_db(BuildState.project(:passed)) == %{state: "passed"}
    end
  end

  describe "summary field" do
    test "defaults to an empty list and does not break project/1 equality" do
      assert BuildState.project(:running) == %BuildState{phase: :running, summary: []}
    end

    test "carries a list of StepSummary structs" do
      step = %Harmont.Apps.StepSummary{key: "clippy", state: "passed"}
      state = %BuildState{phase: :running, summary: [step]}
      assert [%Harmont.Apps.StepSummary{key: "clippy"}] = state.summary
    end
  end
end
