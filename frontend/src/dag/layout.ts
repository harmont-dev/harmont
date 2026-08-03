import { graphlib, layout } from "@dagrejs/dagre";

export type DagInput = {
  id: string;
  depends_on: string[];
};

export const NODE_WIDTH = 160;
export const NODE_HEIGHT = 40;
const RANK_SEP = 40;
const NODE_SEP = 16;

export type PositionedNode = {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
};

export type DagEdge = {
  fromId: string;
  toId: string;
  source: { x: number; y: number };
  target: { x: number; y: number };
  points: { x: number; y: number }[];
};

export type DagLayout = {
  nodes: PositionedNode[];
  edges: DagEdge[];
  width: number;
  height: number;
  lineageOf: (id: string) => Set<string>;
};

export function layoutDag(nodes: DagInput[]): DagLayout {
  if (nodes.length === 0) {
    return {
      nodes: [],
      edges: [],
      width: 0,
      height: 0,
      lineageOf: () => new Set(),
    };
  }

  const g = new graphlib.Graph();
  g.setGraph({
    rankdir: "LR",
    ranksep: RANK_SEP,
    nodesep: NODE_SEP,
    edgesep: NODE_SEP,
  });
  g.setDefaultEdgeLabel(() => ({}));

  for (const node of nodes) {
    g.setNode(node.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
  }

  const byId = new Map(nodes.map((n) => [n.id, n]));

  for (const node of nodes) {
    for (const depId of node.depends_on) {
      if (byId.has(depId)) {
        g.setEdge(depId, node.id);
      }
    }
  }

  layout(g);

  const positioned: PositionedNode[] = nodes.map((node) => {
    const n = g.node(node.id);
    return { id: node.id, x: n.x, y: n.y, width: NODE_WIDTH, height: NODE_HEIGHT };
  });

  const edges: DagEdge[] = g.edges().map((e) => {
    const edge = g.edge(e);
    return {
      fromId: e.v,
      toId: e.w,
      source: g.node(e.v),
      target: g.node(e.w),
      points: edge.points ?? [],
    };
  });

  const graphLabel = g.graph();

  return {
    nodes: positioned,
    edges,
    width: graphLabel.width ?? 0,
    height: graphLabel.height ?? 0,
    lineageOf: buildLineage(nodes),
  };
}

function buildLineage(
  nodes: DagInput[],
): (id: string) => Set<string> {
  const children = new Map<string, string[]>();
  const parents = new Map<string, string[]>();

  for (const node of nodes) {
    parents.set(node.id, [...node.depends_on]);
    for (const depId of node.depends_on) {
      const existing = children.get(depId);
      if (existing) existing.push(node.id);
      else children.set(depId, [node.id]);
    }
  }

  function walk(adj: Map<string, string[]>, id: string): Set<string> {
    const seen = new Set<string>();
    const stack = [id];
    while (stack.length > 0) {
      const cur = stack.pop()!;
      if (seen.has(cur)) continue;
      seen.add(cur);
      const next = adj.get(cur) ?? [];
      for (const n of next) stack.push(n);
    }
    return seen;
  }

  return (id: string): Set<string> => {
    if (!parents.has(id)) return new Set();
    const ancestors = walk(parents, id);
    const descendants = walk(children, id);
    return new Set([...ancestors, ...descendants]);
  };
}
