defmodule Harmont.Engine.Fsm.JobStatePropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Harmont.Engine.Fsm.JobState
  import Harmont.Generators

  @all_states ~w(pending scheduled assigned running passed failed skipped canceling canceled timing_out timed_out)a

  property "transition/2 never raises and returns {:ok, state} | :error for any (state, event)" do
    check all(s <- job_state(), e <- job_event()) do
      case JobState.transition(s, e) do
        {:ok, s2} -> assert s2 in @all_states
        :error -> :ok
      end
    end
  end

  property "terminal states are absorbing — every event is :error from a terminal state" do
    check all(s <- terminal_job_state(), e <- job_event()) do
      assert JobState.transition(s, e) == :error
    end
  end

  property "cast/1 round-trips with Atom.to_string for every valid state" do
    check all(s <- job_state()) do
      assert JobState.cast(Atom.to_string(s)) == {:ok, s}
    end
  end

  property "cast/1 returns :error for any string that is not a known state" do
    valid = Enum.map(@all_states, &Atom.to_string/1)

    check all(junk <- string(:printable), junk not in valid) do
      assert JobState.cast(junk) == :error
    end
  end

  property "from_agent_transition/1 maps only the 6 known proto enums" do
    known =
      ~w(JOB_ASSIGNED_TO_SANDBOX JOB_STARTED JOB_REPORTED_PASSED JOB_REPORTED_FAILED JOB_TIMEOUT_EXPIRED JOB_SANDBOX_LOST)a

    check all(a <- member_of(known)) do
      assert {:ok, _ev} = JobState.from_agent_transition(a)
    end
  end

  property "from_agent_transition/1 rejects unknown proto enums" do
    check all(a <- member_of(~w(UNSPECIFIED BOGUS OTHER JOB_QUEUED)a)) do
      assert JobState.from_agent_transition(a) == :error
    end
  end
end
