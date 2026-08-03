import { layoutPipeline, NODE_W, NODE_H } from './pipeline-dag-layout';
import type { PipelineEdge, PipelineNode } from './pipeline-dag-layout';
import styles from './pipeline-dag.module.css';

export interface PipelineDagProps {
  nodes: PipelineNode[];
  edges: PipelineEdge[];
  /** Accessible description of what the graph shows (also the caption). */
  caption: string;
  /**
   * Cap the rendered width, in px. The graph scales to fit that width; a cap
   * wider than the content column has no effect. Omit to fill the column.
   */
  maxWidth?: number;
}

export function PipelineDag({ nodes, edges, caption, maxWidth }: PipelineDagProps) {
  const layout = layoutPipeline(nodes, edges);
  // Stable per-instance suffix so multiple graphs on a page don't collide
  // on <pattern>/<marker> ids. Derived from node ids — no randomness.
  // Join with '__' (illegal in node slugs) so ids that themselves contain
  // hyphens (e.g. "uv-sync") can't produce a colliding suffix.
  const uid = nodes.map((n) => n.id).join('__');
  return (
    // `not-prose` opts the whole subtree out of Fumadocs/Tailwind `.prose`
    // typography, which otherwise layers figure/figcaption/img margins, borders,
    // and rounding onto our SVG — styling the wrong elements.
    <figure
      className={`${styles.dag} not-prose`}
      role="img"
      aria-labelledby={`caption-${uid}`}
      style={maxWidth ? { maxWidth } : undefined}
    >
      <svg
        className={styles.svg}
        viewBox={`0 0 ${layout.width} ${layout.height}`}
        preserveAspectRatio="xMidYMid meet"
      >
        <defs>
          <pattern
            id={`dots-${uid}`}
            width="20"
            height="20"
            patternUnits="userSpaceOnUse"
          >
            <circle className={styles.dot} cx="2" cy="2" r="1" />
          </pattern>
          <marker
            id={`arrow-${uid}`}
            viewBox="0 0 8 8"
            refX="7"
            refY="4"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path className={styles.arrow} d="M0 0 L8 4 L0 8 z" />
          </marker>
        </defs>
        <rect
          width={layout.width}
          height={layout.height}
          fill={`url(#dots-${uid})`}
        />
        <g>
          {layout.edges.map((e) => (
            <path
              key={`${e.from}-${e.to}`}
              className={styles.edge}
              d={e.d}
              markerEnd={`url(#arrow-${uid})`}
            />
          ))}
        </g>
        <g>
          {layout.nodes.map((n) => (
            <g key={n.id} className={styles.node} data-status={n.status ?? 'passed'}>
              {/* Sharp corners (no rx) match the landing-page DAG and keep all
                  four corners consistent — a rounded bg clashes with the square
                  status bar that caps the left edge. */}
              <rect
                className={styles.nodeBg}
                x={n.x}
                y={n.y}
                width={NODE_W}
                height={NODE_H}
              />
              <rect
                className={styles.nodeBar}
                x={n.x}
                y={n.y}
                width="3"
                height={NODE_H}
              />
              <text
                className={styles.nodeName}
                x={n.x + 14}
                y={n.y + (n.duration ? 18 : 24)}
              >
                {n.label}
              </text>
              {n.duration ? (
                <text className={styles.nodeDuration} x={n.x + 14} y={n.y + 32}>
                  {n.duration}
                </text>
              ) : null}
            </g>
          ))}
        </g>
      </svg>
      <figcaption id={`caption-${uid}`} className={styles.caption}>
        {caption}
      </figcaption>
    </figure>
  );
}
