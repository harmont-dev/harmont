defmodule Harmont.Engine.SchedulingTest do
  use ExUnit.Case, async: true
  alias Harmont.Engine.Scheduling

  # jobs: %{key => state}; deps: [{dependent, prerequisite}]
  test "ready = pending jobs whose prerequisites are all passed/skipped" do
    jobs = %{"a" => :passed, "b" => :pending, "c" => :pending}
    deps = [{"b", "a"}, {"c", "b"}]
    assert Scheduling.ready(jobs, deps) == ["b"]
  end

  test "no prerequisites => ready immediately" do
    assert Scheduling.ready(%{"a" => :pending}, []) == ["a"]
  end

  test "cascade: dependents of a failed prerequisite become skipped (transitively)" do
    jobs = %{"a" => :failed, "b" => :pending, "c" => :pending}
    deps = [{"b", "a"}, {"c", "b"}]
    assert Enum.sort(Scheduling.cascade_skips(jobs, deps)) == ["b", "c"]
  end

  test "cascade ignores already-terminal dependents" do
    jobs = %{"a" => :failed, "b" => :passed}
    deps = [{"b", "a"}]
    assert Scheduling.cascade_skips(jobs, deps) == []
  end
end
