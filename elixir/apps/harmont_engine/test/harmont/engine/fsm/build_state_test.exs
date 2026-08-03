defmodule Harmont.Engine.Fsm.BuildStateTest do
  use ExUnit.Case, async: true
  alias Harmont.Engine.Fsm.BuildState

  test "all passed -> passed" do
    assert BuildState.recompute([:passed, :passed, :skipped], false) == :passed
  end

  test "any failed once all terminal -> failed" do
    assert BuildState.recompute([:passed, :failed], false) == :failed
  end

  test "a failure with work still running -> failing" do
    assert BuildState.recompute([:failed, :running], false) == :failing
  end

  test "running with no failures -> running" do
    assert BuildState.recompute([:running, :pending], false) == :running
  end

  test "fresh build with only pending -> scheduled" do
    assert BuildState.recompute([:pending, :pending], false) == :scheduled
  end

  test "cancel flag dominates: terminal -> canceled, else canceling" do
    assert BuildState.recompute([:canceled, :canceled], true) == :canceled
    assert BuildState.recompute([:running, :canceled], true) == :canceling
  end
end
