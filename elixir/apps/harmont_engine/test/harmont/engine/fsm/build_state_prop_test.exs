defmodule Harmont.Engine.Fsm.BuildStatePropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Harmont.Engine.Fsm.{BuildState, JobState}
  import Harmont.Generators

  defp states, do: list_of(job_state(), min_length: 1, max_length: 10)

  property "recompute always returns a valid BuildState atom" do
    check all(js <- states(), cancel <- boolean()) do
      assert BuildState.recompute(js, cancel) in ~w(scheduled running failing passed failed canceling canceled)a
    end
  end

  property "all-terminal + any-failed => :failed (no cancel)" do
    # Construct directly: pick exactly one failure state plus 0..9 other terminals.
    # This avoids StreamData.filter so the generator never raises FilterTooNarrowError.
    check all(
            failure <- member_of(~w(failed timed_out)a),
            others <-
              list_of(member_of(~w(passed failed skipped canceled timed_out)a), max_length: 9)
          ) do
      js = [failure | others]
      assert BuildState.recompute(js, false) == :failed
    end
  end

  property "all passed/skipped => :passed (no cancel)" do
    check all(js <- list_of(member_of(~w(passed skipped)a), min_length: 1, max_length: 10)) do
      assert BuildState.recompute(js, false) == :passed
    end
  end

  property "cancel flag dominates: all-terminal => :canceled, else :canceling" do
    check all(js <- states()) do
      all_terminal? = Enum.all?(js, &JobState.terminal?/1)
      expected = if all_terminal?, do: :canceled, else: :canceling
      assert BuildState.recompute(js, true) == expected
    end
  end

  property "any in-progress job that is not failing yields :running once anything has started" do
    # at least one non-terminal job that has progressed past scheduled, no failures
    check all(
            started <- member_of(~w(assigned running)a),
            rest <- list_of(member_of(~w(pending scheduled passed skipped)a), max_length: 6)
          ) do
      js = [started | rest]
      assert BuildState.recompute(js, false) == :running
    end
  end
end
