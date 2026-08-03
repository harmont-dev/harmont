defmodule HarmontIr.PlannerTest do
  use ExUnit.Case, async: true
  alias HarmontIr.{Flat, Graph, Planner}

  defp cmd(key, opts \\ []),
    do: %HarmontIr.CommandStep{
      key: key,
      cmd: "echo #{key}",
      builds_in: opts[:builds_in],
      image: opts[:image],
      env: opts[:env] || %{}
    }

  defp flat(steps, opts \\ []),
    do: %Flat{
      version: "0",
      default_image: opts[:default_image],
      env: opts[:env] || %{},
      steps: steps
    }

  test "wait inserts depends_on edges from every post-wait to every pre-wait command" do
    f = flat([cmd("a"), cmd("b"), {:wait, false}, cmd("c"), cmd("d")])
    assert {:ok, g} = Planner.plan(f)
    assert Enum.sort(Graph.prerequisites(g, "c")) == ["a", "b"]
    assert Enum.sort(Graph.prerequisites(g, "d")) == ["a", "b"]
    assert Graph.prerequisites(g, "a") == []
    assert Graph.edge_kind(g, "c", "a") == :depends_on
  end

  test "consecutive waits collapse; pre-wait set accumulates" do
    f = flat([cmd("a"), {:wait, false}, {:wait, false}, cmd("b")])
    assert {:ok, g} = Planner.plan(f)
    assert Graph.prerequisites(g, "b") == ["a"]
  end

  test "buildsIn creates a builds_in edge" do
    f = flat([cmd("a"), cmd("b", builds_in: "a")])
    assert {:ok, g} = Planner.plan(f)
    assert Graph.edge_kind(g, "b", "a") == :builds_in
  end

  test "env resolves pipeline env merged under per-step env" do
    f = flat([cmd("a", env: %{"X" => "step"})], env: %{"X" => "pipe", "Y" => "pipe"})
    assert {:ok, g} = Planner.plan(f)
    assert %{env: %{"X" => "step", "Y" => "pipe"}} = Graph.fetch!(g, "a")
  end

  test "root imageless steps inherit default_image; non-root keep nil image" do
    f = flat([cmd("a"), cmd("b", builds_in: "a")], default_image: "ubuntu:24.04")
    assert {:ok, g} = Planner.plan(f)
    assert Graph.fetch!(g, "a").step.image == "ubuntu:24.04"
    assert Graph.fetch!(g, "b").step.image == nil
  end

  test "duplicate keys rejected" do
    assert {:error, {:duplicate_key, "a"}} = Planner.plan(flat([cmd("a"), cmd("a")]))
  end

  test "unknown buildsIn target rejected" do
    assert {:error, {:unknown_dependency, "b", "z"}} =
             Planner.plan(flat([cmd("b", builds_in: "z")]))
  end

  test "cycle via buildsIn rejected" do
    f = flat([cmd("a", builds_in: "b"), cmd("b", builds_in: "a")])
    assert {:error, {:cycle, cycle}} = Planner.plan(f)
    assert Enum.sort(cycle) == ["a", "b"]
  end

  test "plan/1 carries the flat pipeline timeout onto the graph" do
    f = %HarmontIr.Flat{
      version: "0",
      default_image: nil,
      timeout_seconds: 900,
      env: %{},
      steps: [cmd("a")]
    }

    assert {:ok, g} = HarmontIr.Planner.plan(f)
    assert HarmontIr.Graph.timeout_seconds(g) == 900
  end
end
