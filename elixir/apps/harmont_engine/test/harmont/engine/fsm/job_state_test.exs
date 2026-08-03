defmodule Harmont.Engine.Fsm.JobStateTest do
  use ExUnit.Case, async: true
  alias Harmont.Engine.Fsm.JobState

  test "happy path: pending -> scheduled -> assigned -> running -> passed" do
    assert {:ok, :scheduled} = JobState.transition(:pending, :ready_to_schedule)
    assert {:ok, :assigned} = JobState.transition(:scheduled, :assigned_to_sandbox)
    assert {:ok, :running} = JobState.transition(:assigned, :started)
    assert {:ok, :passed} = JobState.transition(:running, :reported_passed)
  end

  test "cache hit short-circuits scheduled -> passed" do
    assert {:ok, :passed} = JobState.transition(:scheduled, :cache_hit)
  end

  test "cancel: pending/scheduled cancel immediately; running enters canceling" do
    assert {:ok, :canceled} = JobState.transition(:pending, :cancel_requested)
    assert {:ok, :canceled} = JobState.transition(:scheduled, :cancel_requested)
    assert {:ok, :canceling} = JobState.transition(:running, :cancel_requested)
    assert {:ok, :canceled} = JobState.transition(:canceling, :reported_failed)
  end

  test "timeout: running -> timing_out -> timed_out" do
    assert {:ok, :timing_out} = JobState.transition(:running, :timeout_expired)
    assert {:ok, :timed_out} = JobState.transition(:timing_out, :reported_failed)
    assert {:ok, :timed_out} = JobState.transition(:timing_out, :sandbox_lost)
  end

  test "sandbox lost fails assigned/running" do
    assert {:ok, :failed} = JobState.transition(:assigned, :sandbox_lost)
    assert {:ok, :failed} = JobState.transition(:running, :sandbox_lost)
  end

  test "illegal arcs return :error" do
    assert :error = JobState.transition(:passed, :started)
    assert :error = JobState.transition(:pending, :reported_passed)
  end

  test "canceling does NOT accept timeout_expired (delta: review fix)" do
    assert :error = JobState.transition(:canceling, :timeout_expired)
  end

  test "terminal?/1" do
    assert JobState.terminal?(:passed)
    assert JobState.terminal?(:failed)
    assert JobState.terminal?(:skipped)
    assert JobState.terminal?(:canceled)
    assert JobState.terminal?(:timed_out)
    refute JobState.terminal?(:running)
  end

  test "cast/1 returns {:ok, atom} for known states and :error for unknown" do
    assert {:ok, :pending} = JobState.cast("pending")
    assert {:ok, :scheduled} = JobState.cast("scheduled")
    assert {:ok, :assigned} = JobState.cast("assigned")
    assert {:ok, :running} = JobState.cast("running")
    assert {:ok, :passed} = JobState.cast("passed")
    assert {:ok, :failed} = JobState.cast("failed")
    assert {:ok, :skipped} = JobState.cast("skipped")
    assert {:ok, :canceling} = JobState.cast("canceling")
    assert {:ok, :canceled} = JobState.cast("canceled")
    assert {:ok, :timing_out} = JobState.cast("timing_out")
    assert {:ok, :timed_out} = JobState.cast("timed_out")
    assert :error = JobState.cast("bogus")
    assert :error = JobState.cast("unknown_rolling_deploy_state")
    assert :error = JobState.cast("")
  end

  test "cast!/1 returns the atom for a known state and raises on unknown" do
    assert :running = JobState.cast!("running")
    assert_raise MatchError, fn -> JobState.cast!("bogus") end
  end

  test "from_agent_transition/1 maps all 6 proto values and UNSPECIFIED -> :error" do
    assert {:ok, :assigned_to_sandbox} = JobState.from_agent_transition(:JOB_ASSIGNED_TO_SANDBOX)
    assert {:ok, :started} = JobState.from_agent_transition(:JOB_STARTED)
    assert {:ok, :reported_passed} = JobState.from_agent_transition(:JOB_REPORTED_PASSED)
    assert {:ok, :reported_failed} = JobState.from_agent_transition(:JOB_REPORTED_FAILED)
    assert {:ok, :timeout_expired} = JobState.from_agent_transition(:JOB_TIMEOUT_EXPIRED)
    assert {:ok, :sandbox_lost} = JobState.from_agent_transition(:JOB_SANDBOX_LOST)
    assert :error = JobState.from_agent_transition(:JOB_TRANSITION_UNSPECIFIED)
    assert :error = JobState.from_agent_transition(:OTHER_UNKNOWN)
  end

  test "build_timeout drives every non-terminal state to :timed_out" do
    for s <- [:pending, :scheduled, :assigned, :running, :timing_out, :canceling] do
      assert JobState.transition(s, :build_timeout) == {:ok, :timed_out}
    end
  end

  test "build_timeout is dropped (:error) from terminal states" do
    for s <- [:passed, :failed, :skipped, :canceled, :timed_out] do
      assert JobState.transition(s, :build_timeout) == :error
    end
  end
end
