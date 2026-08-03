defmodule HarmontIr.PlannerPropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias HarmontIr.{CommandStep, Flat, Graph, Planner}
  import HarmontIr.Generators

  property "planning a valid pipeline yields an acyclic graph with one node per command step" do
    check all(flat <- flat_pipeline()) do
      assert {:ok, g} = Planner.plan(flat)
      cmd_count = Enum.count(flat.steps, &match?(%CommandStep{}, &1))
      assert Graph.node_count(g) == cmd_count
      # acyclic by construction
      assert {:ok, _order} = Graph.topo_sort(g)
    end
  end

  property "every wait barrier makes each post-wait command depend on every pre-wait command" do
    check all(flat <- flat_pipeline()) do
      assert {:ok, g} = Planner.plan(flat)

      # Reconstruct the planner's wait-edge contract: a wait barrier links every
      # following command (until the next wait) to every command seen before
      # the barrier; pre accumulates across consecutive waits.
      {expected, _pre, _pending} =
        Enum.reduce(flat.steps, {MapSet.new(), [], []}, fn
          {:wait, _}, {edges, pre, pending} ->
            {edges, pre ++ pending, []}

          %CommandStep{key: k}, {edges, pre, pending} ->
            new = for p <- pre, into: MapSet.new(), do: {k, p}
            {MapSet.union(edges, new), pre, [k | pending]}
        end)

      for {dep, pre} <- expected do
        assert pre in Graph.prerequisites(g, dep)
      end
    end
  end

  property "duplicate keys always error" do
    check all(k <- step_key()) do
      dup = %Flat{
        version: "0",
        env: %{},
        steps: [
          %CommandStep{key: k, cmd: "a", env: %{}},
          %CommandStep{key: k, cmd: "b", env: %{}}
        ]
      }

      assert {:error, {:duplicate_key, ^k}} = Planner.plan(dup)
    end
  end

  property "buildsIn an unknown key always errors" do
    check all(k <- step_key(), parent <- step_key(), k != parent) do
      flat = %Flat{
        version: "0",
        env: %{},
        steps: [%CommandStep{key: k, cmd: "x", builds_in: parent, env: %{}}]
      }

      assert {:error, {:unknown_dependency, ^k, ^parent}} = Planner.plan(flat)
    end
  end
end
