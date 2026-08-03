defmodule Harmont.Engine.SchedulingPropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Harmont.Engine.Scheduling
  import Harmont.Generators

  property "ready returns only :pending jobs whose prereqs are all passed/skipped" do
    check all({states, deps} <- states_and_deps()) do
      ready = Scheduling.ready(states, deps)
      prereqs = Enum.group_by(deps, fn {d, _p} -> d end, fn {_d, p} -> p end)

      for key <- ready do
        assert states[key] == :pending
        assert Enum.all?(Map.get(prereqs, key, []), &(states[&1] in ~w(passed skipped)a))
      end
    end
  end

  property "cascade_skips is idempotent (a fixpoint)" do
    check all({states, deps} <- states_and_deps()) do
      once = Scheduling.cascade_skips(states, deps)
      states2 = Enum.reduce(once, states, fn k, acc -> Map.put(acc, k, :skipped) end)
      twice = Scheduling.cascade_skips(states2, deps)
      assert twice == []
    end
  end

  property "cascade only ever skips :pending jobs" do
    check all({states, deps} <- states_and_deps()) do
      for k <- Scheduling.cascade_skips(states, deps) do
        assert states[k] == :pending
      end
    end
  end

  property "every cascade-skipped job transitively depends on a failed/timed_out job" do
    check all({states, deps} <- states_and_deps()) do
      prereqs = Enum.group_by(deps, fn {d, _p} -> d end, fn {_d, p} -> p end)
      skips = Scheduling.cascade_skips(states, deps)
      skip_set = MapSet.new(skips)

      for k <- skips do
        # a skipped job must have at least one prereq that is itself failed/timed_out
        # or itself a cascade-skipped job (transitive taint)
        ps = Map.get(prereqs, k, [])

        assert Enum.any?(ps, fn p ->
                 states[p] in ~w(failed timed_out)a or MapSet.member?(skip_set, p)
               end)
      end
    end
  end

  property "a job is never both ready and cascade-skipped" do
    check all({states, deps} <- states_and_deps()) do
      ready = MapSet.new(Scheduling.ready(states, deps))
      skips = MapSet.new(Scheduling.cascade_skips(states, deps))
      assert MapSet.disjoint?(ready, skips)
    end
  end
end
