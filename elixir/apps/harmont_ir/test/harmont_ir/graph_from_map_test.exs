defmodule HarmontIr.GraphFromMapTest do
  use ExUnit.Case, async: true
  alias HarmontIr.{CommandStep, Graph, Transition}

  @ir %{
    "version" => "0",
    "default_image" => "ubuntu:24.04",
    "graph" => %{
      "nodes" => [
        %{
          "step" => %{
            "key" => "base",
            "cmd" => "apt-get update",
            "label" => "base",
            "image" => "ubuntu:24.04",
            "cache" => %{"policy" => "ttl", "key" => nil}
          },
          "env" => %{"CI" => "true"}
        },
        %{
          "step" => %{"key" => "test", "cmd" => "cargo test", "label" => "test"},
          "env" => %{"CI" => "true"}
        }
      ],
      "node_holes" => [],
      "edge_property" => "directed",
      "edges" => [[0, 1, "builds_in"]]
    }
  }

  test "parses the graph-form IR into a %Graph{} with nodes, env, edge, and derived builds_in" do
    assert {:ok, graph} = Graph.from_map(@ir)

    assert Enum.sort(Graph.keys(graph)) == ["base", "test"]
    assert Graph.default_image(graph) == "ubuntu:24.04"

    assert %Transition{step: %CommandStep{} = base, env: %{"CI" => "true"}} =
             Graph.fetch!(graph, "base")

    assert base.cmd == "apt-get update"
    assert base.image == "ubuntu:24.04"
    assert base.cache.policy == "ttl"
    assert base.builds_in == nil

    assert %Transition{step: %CommandStep{} = test} = Graph.fetch!(graph, "test")
    # builds_in derived from the [0,1,"builds_in"] edge: test boots from base
    assert test.builds_in == "base"

    # edge: dependent "test" -> prerequisite "base", kind :builds_in
    assert Graph.prerequisites(graph, "test") == ["base"]
    assert Graph.edge_kind(graph, "test", "base") == :builds_in
  end

  test "maps depends_on edges and omits builds_in for them" do
    ir = put_in(@ir, ["graph", "edges"], [[0, 1, "depends_on"]])
    assert {:ok, graph} = Graph.from_map(ir)
    assert Graph.edge_kind(graph, "test", "base") == :depends_on
    assert Graph.fetch!(graph, "test").step.builds_in == nil
  end

  test "default_image is nil when absent" do
    ir = Map.delete(@ir, "default_image")
    assert {:ok, graph} = Graph.from_map(ir)
    assert Graph.default_image(graph) == nil
  end

  test "from_map/1 reads the pipeline-level timeout_seconds" do
    ir = %{
      "version" => "0",
      "timeout_seconds" => 1800,
      "graph" => %{
        "nodes" => [%{"step" => %{"key" => "a", "cmd" => "echo a"}, "env" => %{}}],
        "edges" => []
      }
    }

    assert {:ok, graph} = Graph.from_map(ir)
    assert Graph.timeout_seconds(graph) == 1800
  end

  test "from_map/1 defaults pipeline timeout to nil when absent" do
    ir = %{
      "version" => "0",
      "graph" => %{
        "nodes" => [%{"step" => %{"key" => "a", "cmd" => "echo a"}, "env" => %{}}],
        "edges" => []
      }
    }

    assert {:ok, graph} = Graph.from_map(ir)
    assert Graph.timeout_seconds(graph) == nil
  end
end
