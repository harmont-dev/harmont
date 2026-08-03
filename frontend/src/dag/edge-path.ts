import { NODE_WIDTH, type DagEdge } from "./layout";

export function edgePath(edge: DagEdge): string {
  const halfW = NODE_WIDTH / 2;
  const { source, target } = edge;

  const x0 = source.x + halfW;
  const y0 = source.y;
  const x1 = target.x - halfW;
  const y1 = target.y;

  const midX = (x0 + x1) / 2;

  return `M ${x0} ${y0} L ${midX} ${y0} L ${midX} ${y1} L ${x1} ${y1}`;
}
