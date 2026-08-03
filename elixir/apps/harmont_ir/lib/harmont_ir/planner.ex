defmodule HarmontIr.Planner do
  @moduledoc """
  Lowers a flat v0 pipeline into a validated DAG. This Elixir planner is the
  authority for pipeline planning:

    * wait barrier  -> :depends_on edges (post-wait depends on all pre-wait)
    * buildsIn      -> :builds_in edge (dependent -> prerequisite)
    * duplicate keys, unknown deps, cycles are errors
    * env = pipeline env merged under per-step env (step wins)
    * default_image applied to imageless ROOT steps only (mirrors the
      hm-pipeline-ir Rust crate which applies default_image to root steps
      without an explicit image)

  The graph is built in three passes (build_graph/3):
    1. Seed nodes with per-step raw image and resolved env.
    2. Add all edges (wait barriers + buildsIn).
    3. Apply default_image to imageless roots (Graph.roots/1 is the
       authoritative root set — after edges, unlike the buildsIn-only
       approximation).
  """
  alias HarmontIr.{CommandStep, Flat, Graph, PlanError, Transition}

  @spec plan(Flat.t()) :: {:ok, Graph.t()} | {:error, PlanError.t()}
  def plan(%Flat{} = flat) do
    commands = for %CommandStep{} = c <- flat.steps, do: c

    with :ok <- check_duplicates(commands),
         {:ok, deps} <- collect_deps(flat.steps, commands) do
      graph = build_graph(flat, commands, deps)

      case Graph.topo_sort(graph) do
        {:ok, _} -> {:ok, graph}
        {:error, {:cycle, keys}} -> {:error, {:cycle, keys}}
      end
    end
  end

  # --- validation -----------------------------------------------------------

  defp check_duplicates(commands) do
    commands
    |> Enum.reduce_while(MapSet.new(), fn %{key: k}, seen ->
      if MapSet.member?(seen, k),
        do: {:halt, {:dup, k}},
        else: {:cont, MapSet.put(seen, k)}
    end)
    |> case do
      {:dup, k} -> {:error, {:duplicate_key, k}}
      _ -> :ok
    end
  end

  # Build the {dependent, prerequisite, kind} edge list, validating buildsIn.
  defp collect_deps(steps, commands) do
    keyset = MapSet.new(commands, & &1.key)

    with {:ok, builds_in} <- builds_in_edges(commands, keyset) do
      {:ok, builds_in ++ wait_edges(steps)}
    end
  end

  defp builds_in_edges(commands, keyset) do
    Enum.reduce_while(commands, {:ok, []}, fn
      %{key: k, builds_in: parent}, {:ok, acc} when is_binary(parent) ->
        if MapSet.member?(keyset, parent),
          do: {:cont, {:ok, [{k, parent, :builds_in} | acc]}},
          else: {:halt, {:error, {:unknown_dependency, k, parent}}}

      _step, acc ->
        {:cont, acc}
    end)
  end

  # Walk steps; a wait barrier links every following command (until the next
  # wait) to every command seen before the barrier. Pre-wait set accumulates
  # across multiple consecutive waits (consecutive waits collapse).
  defp wait_edges(steps) do
    {edges, _pre, _pending} =
      Enum.reduce(steps, {[], [], []}, fn
        {:wait, _cof}, {edges, pre, pending} ->
          {edges, pre ++ pending, []}

        %CommandStep{key: k}, {edges, pre, pending} ->
          new_edges = for p <- pre, do: {k, p, :depends_on}
          {new_edges ++ edges, pre, [k | pending]}
      end)

    edges
  end

  # --- graph construction (Step-4 ordering) ---------------------------------

  # Three-pass build:
  #   pass 1: seed all nodes with raw per-step image and resolved env
  #   pass 2: add all edges (wait barriers + buildsIn)
  #   pass 3: fill default_image on imageless graph roots (authoritative root
  #           set comes from the edge-complete graph, not a buildsIn-only approx)
  defp build_graph(%Flat{} = flat, commands, deps) do
    g0 =
      Enum.reduce(commands, Graph.new(flat.default_image, flat.timeout_seconds), fn c, g ->
        Graph.add_node(g, %Transition{step: c, env: Map.merge(flat.env, c.env)})
      end)

    g1 = add_edges(g0, deps)

    Enum.reduce(Graph.roots(g1), g1, fn key, g ->
      t = Graph.fetch!(g, key)

      if t.step.image == nil and flat.default_image != nil do
        Graph.add_node(g, %{t | step: %{t.step | image: flat.default_image}})
      else
        g
      end
    end)
  end

  defp add_edges(graph, deps),
    do: Enum.reduce(deps, graph, fn {dep, pre, kind}, g -> Graph.add_edge(g, dep, pre, kind) end)
end
