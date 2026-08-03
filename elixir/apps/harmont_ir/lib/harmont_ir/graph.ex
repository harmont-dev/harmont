defmodule HarmontIr.Graph do
  @moduledoc """
  Pipeline DAG. Vertices are step keys (strings); payloads live in `nodes`.
  Edges are labelled `:builds_in | :depends_on` and point dependent ->
  prerequisite (dependent -> its prerequisite).
  """
  use TypedStruct
  alias HarmontIr.{Cache, CommandStep, Transition}

  @type edge_kind :: :builds_in | :depends_on

  typedstruct enforce: true do
    field :g, Graph.t()
    field :nodes, %{String.t() => Transition.t()}, default: %{}
    field :default_image, String.t() | nil, enforce: false, default: nil
    field :timeout_seconds, non_neg_integer() | nil, enforce: false, default: nil
  end

  @spec new(String.t() | nil, non_neg_integer() | nil) :: t()
  def new(default_image, timeout_seconds \\ nil),
    do: %__MODULE__{
      g: Graph.new(),
      nodes: %{},
      default_image: default_image,
      timeout_seconds: timeout_seconds
    }

  @spec add_node(t(), Transition.t()) :: t()
  def add_node(%__MODULE__{} = pg, %Transition{step: %{key: k}} = t) do
    %{pg | g: Graph.add_vertex(pg.g, k), nodes: Map.put(pg.nodes, k, t)}
  end

  @doc "Add an edge dependent -> prerequisite with a kind label."
  @spec add_edge(t(), String.t(), String.t(), edge_kind()) :: t()
  def add_edge(%__MODULE__{} = pg, dependent, prerequisite, kind) do
    %{pg | g: Graph.add_edge(pg.g, dependent, prerequisite, label: kind)}
  end

  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: n}), do: map_size(n)

  @spec default_image(t()) :: String.t() | nil
  def default_image(%__MODULE__{default_image: d}), do: d

  @spec timeout_seconds(t()) :: non_neg_integer() | nil
  def timeout_seconds(%__MODULE__{timeout_seconds: t}), do: t

  @spec fetch!(t(), String.t()) :: Transition.t()
  def fetch!(%__MODULE__{nodes: n}, key), do: Map.fetch!(n, key)

  @doc "Returns all node keys. Order is unspecified (delegates to `Map.keys/1`)."
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{nodes: n}), do: Map.keys(n)

  @doc "Keys this node depends on (out-neighbours)."
  @spec prerequisites(t(), String.t()) :: [String.t()]
  def prerequisites(%__MODULE__{g: g}, key), do: Enum.sort(Graph.out_neighbors(g, key))

  @doc "Keys that depend on this node (in-neighbours)."
  @spec dependents(t(), String.t()) :: [String.t()]
  def dependents(%__MODULE__{g: g}, key), do: Enum.sort(Graph.in_neighbors(g, key))

  @spec roots(t()) :: [String.t()]
  def roots(%__MODULE__{g: g} = pg),
    do: pg |> keys() |> Enum.filter(&(Graph.out_neighbors(g, &1) == [])) |> Enum.sort()

  @spec edge_kind(t(), String.t(), String.t()) :: edge_kind() | nil
  def edge_kind(%__MODULE__{g: g}, dependent, prerequisite) do
    case Graph.edges(g, dependent, prerequisite) do
      [%Graph.Edge{label: k} | _] -> k
      _ -> nil
    end
  end

  @doc "Returns {:ok, topo_order} or {:error, {:cycle, keys}}."
  @spec topo_sort(t()) :: {:ok, [String.t()]} | {:error, {:cycle, [String.t()]}}
  def topo_sort(%__MODULE__{g: g}) do
    case Graph.topsort(g) do
      false -> {:error, {:cycle, find_cycle_keys(g)}}
      order -> {:ok, order}
    end
  end

  defp find_cycle_keys(g) do
    case Graph.loop_vertices(g) do
      # `topsort/1` returning `false` guarantees a cycle exists somewhere in the
      # graph, so `Enum.find` will always locate a strongly-connected component
      # of size > 1.  The `[]` default is the theoretically-unreachable case —
      # kept only to satisfy the compiler's exhaustiveness requirement.
      [] -> g |> Graph.strong_components() |> Enum.find([], &(length(&1) > 1))
      loops -> loops
    end
  end

  @doc """
  Build a `%Graph{}` from the canonical graph-form v0 IR emitted by `hm` /
  `hm-pipeline-ir` (petgraph-serde). `nodes` are positional (index 0..N);
  `edges` are `[from_index, to_index, kind]` where `from` is the prerequisite
  and `to` is the dependent.

  A `"builds_in"` edge also sets the dependent node's `CommandStep.builds_in`
  lineage hint, which `Materialize` reads to boot the child from the parent's
  snapshot.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"version" => "0", "graph" => %{"nodes" => nodes} = g} = m)
      when is_list(nodes) do
    edges = Map.get(g, "edges", [])

    # Tolerate a malformed node (non-map `step`, missing `key`) by yielding nil,
    # which the guard below turns into a clean error instead of a raise.
    keys =
      Enum.map(nodes, fn
        %{"step" => %{"key" => k}} -> k
        _ -> nil
      end)

    if Enum.any?(keys, &is_nil/1) do
      {:error, {:bad_graph_ir, :missing_step_key}}
    else
      # For each builds_in edge [from, to, "builds_in"], record to -> parent_key.
      # A node has at most one incoming builds_in edge; the comprehension keeps
      # whichever appears last, which is fine for valid (acyclic) IR.
      builds_in_by_index =
        for [from, to, "builds_in"] <- edges, into: %{} do
          {to, Enum.at(keys, from)}
        end

      graph =
        nodes
        |> Enum.with_index()
        |> Enum.reduce(new(m["default_image"], m["timeout_seconds"]), fn {node, idx}, acc ->
          add_node(acc, node_to_transition(node, builds_in_by_index[idx]))
        end)
        |> add_ir_edges(edges, keys)

      {:ok, graph}
    end
  end

  def from_map(_), do: {:error, {:bad_graph_ir, :malformed}}

  # ---------------------------------------------------------------------------
  # from_map helpers
  # ---------------------------------------------------------------------------

  defp add_ir_edges(graph, edges, keys) do
    Enum.reduce(edges, graph, fn [from, to, kind], acc ->
      add_edge(acc, Enum.at(keys, to), Enum.at(keys, from), edge_kind_atom(kind))
    end)
  end

  defp node_to_transition(%{"step" => step} = node, builds_in) do
    cs = %CommandStep{
      key: step["key"],
      cmd: step["cmd"],
      label: step["label"],
      image: step["image"],
      env: step["env"] || %{},
      builds_in: builds_in,
      timeout_seconds: step["timeout_seconds"],
      cache: parse_node_cache(step["cache"]),
      runner: step["runner"],
      runner_args: step["runner_args"]
    }

    %Transition{step: cs, env: node["env"] || %{}}
  end

  defp parse_node_cache(nil), do: nil

  defp parse_node_cache(c) when is_map(c) do
    case Cache.from_map(c) do
      {:ok, cache} -> cache
      {:error, _} -> nil
    end
  end

  defp edge_kind_atom("builds_in"), do: :builds_in
  defp edge_kind_atom("depends_on"), do: :depends_on
  defp edge_kind_atom(_other), do: :depends_on
end
