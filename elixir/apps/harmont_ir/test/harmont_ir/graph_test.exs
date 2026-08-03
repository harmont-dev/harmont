defmodule HarmontIr.GraphTest do
  use ExUnit.Case, async: true
  alias HarmontIr.{CommandStep, Graph, Transition}

  defp step(key, opts \\ []),
    do: %CommandStep{key: key, cmd: "echo #{key}", image: opts[:image], env: opts[:env] || %{}}

  test "build a graph, add nodes and edges, traverse parents/children" do
    g =
      Graph.new("ubuntu:24.04")
      |> Graph.add_node(%Transition{step: step("a"), env: %{"X" => "1"}})
      |> Graph.add_node(%Transition{step: step("b"), env: %{}})
      |> Graph.add_edge("b", "a", :builds_in)

    assert Graph.node_count(g) == 2
    assert Graph.default_image(g) == "ubuntu:24.04"
    assert %Transition{env: %{"X" => "1"}} = Graph.fetch!(g, "a")
    # edge points dependent -> prerequisite
    assert Graph.prerequisites(g, "b") == ["a"]
    assert Graph.dependents(g, "a") == ["b"]
    assert Graph.edge_kind(g, "b", "a") == :builds_in
  end

  test "roots are nodes with no prerequisites" do
    g =
      Graph.new(nil)
      |> Graph.add_node(%Transition{step: step("a"), env: %{}})
      |> Graph.add_node(%Transition{step: step("b"), env: %{}})
      |> Graph.add_edge("b", "a", :depends_on)

    assert Graph.roots(g) == ["a"]
  end

  test "topo_sort returns ok with all keys for a DAG" do
    g =
      Graph.new(nil)
      |> Graph.add_node(%Transition{step: step("a"), env: %{}})
      |> Graph.add_node(%Transition{step: step("b"), env: %{}})
      |> Graph.add_node(%Transition{step: step("c"), env: %{}})
      |> Graph.add_edge("b", "a", :builds_in)
      |> Graph.add_edge("c", "b", :depends_on)

    assert {:ok, order} = Graph.topo_sort(g)
    assert Enum.sort(order) == ["a", "b", "c"]
  end

  test "topo_sort returns error with cycle keys for a cyclic graph" do
    g =
      Graph.new(nil)
      |> Graph.add_node(%Transition{step: step("a"), env: %{}})
      |> Graph.add_node(%Transition{step: step("b"), env: %{}})
      |> Graph.add_edge("a", "b", :builds_in)
      |> Graph.add_edge("b", "a", :builds_in)

    assert {:error, {:cycle, cycle}} = Graph.topo_sort(g)
    assert Enum.sort(cycle) == ["a", "b"]
  end
end
