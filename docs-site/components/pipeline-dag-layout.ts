export type DagStatus = 'passed' | 'running' | 'queued';

export interface PipelineNode {
  id: string;
  label: string;
  duration?: string;
  status?: DagStatus;
}

export interface PipelineEdge {
  from: string;
  to: string;
}

export interface PositionedNode extends PipelineNode {
  x: number;
  y: number;
}

export interface PositionedEdge {
  from: string;
  to: string;
  d: string;
}

export interface DagLayout {
  width: number;
  height: number;
  nodes: PositionedNode[];
  edges: PositionedEdge[];
}

export const NODE_W = 160;
export const NODE_H = 40;
export const COL_GAP = 72;
export const ROW_GAP = 20;
export const PAD = 16;

export function layoutPipeline(
  nodes: PipelineNode[],
  edges: PipelineEdge[],
): DagLayout {
  if (nodes.length === 0) return { width: 0, height: 0, nodes: [], edges: [] };
  const ids = new Set(nodes.map((n) => n.id));
  for (const e of edges) {
    if (!ids.has(e.from) || !ids.has(e.to)) {
      throw new Error(
        `pipeline-dag: edge ${e.from}→${e.to} references an unknown node`,
      );
    }
  }

  // longest-path rank: 0 if no parents, else max(parent rank) + 1
  const parents = new Map<string, string[]>();
  for (const n of nodes) parents.set(n.id, []);
  for (const e of edges) parents.get(e.to)!.push(e.from);

  const rank = new Map<string, number>();
  // `seen` tracks the current DFS path (added on entry, removed on return) so
  // siblings reuse it safely; `rank` memoizes finished nodes across paths.
  const computeRank = (id: string, seen: Set<string>): number => {
    const cached = rank.get(id);
    if (cached !== undefined) return cached;
    if (seen.has(id)) throw new Error(`pipeline-dag: cycle detected at node ${id}`);
    seen.add(id);
    const ps = parents.get(id)!;
    const r = ps.length === 0 ? 0 : Math.max(...ps.map((p) => computeRank(p, seen))) + 1;
    seen.delete(id);
    rank.set(id, r);
    return r;
  };
  for (const n of nodes) computeRank(n.id, new Set());

  // group ids by rank, preserving input order within a rank
  const ranks: string[][] = [];
  for (const n of nodes) {
    const r = rank.get(n.id)!;
    (ranks[r] ??= []).push(n.id);
  }
  const maxRows = Math.max(...ranks.map((r) => r.length));
  const colHeight = maxRows * NODE_H + (maxRows - 1) * ROW_GAP;

  const pos = new Map<string, { x: number; y: number }>();
  ranks.forEach((rankIds, r) => {
    const total = rankIds.length * NODE_H + (rankIds.length - 1) * ROW_GAP;
    const startY = PAD + (colHeight - total) / 2;
    rankIds.forEach((id, i) => {
      pos.set(id, {
        x: PAD + r * (NODE_W + COL_GAP),
        y: startY + i * (NODE_H + ROW_GAP),
      });
    });
  });

  const positionedNodes: PositionedNode[] = nodes.map((n) => ({
    ...n,
    x: pos.get(n.id)!.x,
    y: pos.get(n.id)!.y,
  }));

  const positionedEdges: PositionedEdge[] = edges.map((e) => {
    const s = pos.get(e.from)!;
    const t = pos.get(e.to)!;
    const sx = s.x + NODE_W;
    const sy = s.y + NODE_H / 2;
    const tx = t.x;
    const ty = t.y + NODE_H / 2;
    const mx = (sx + tx) / 2;
    return {
      from: e.from,
      to: e.to,
      d: `M${sx} ${sy} C${mx} ${sy} ${mx} ${ty} ${tx} ${ty}`,
    };
  });

  const width = PAD * 2 + ranks.length * NODE_W + (ranks.length - 1) * COL_GAP;
  const height = PAD * 2 + colHeight;
  return { width, height, nodes: positionedNodes, edges: positionedEdges };
}
