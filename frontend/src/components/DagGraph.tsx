import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import { type DagLayout, type PositionedNode, type DagEdge } from "../dag/layout";
import { edgePath } from "../dag/edge-path";

export type DagGraphProps = {
  layout: DagLayout;
  nodeLabel: (id: string) => string;
  nodeColor?: (id: string) => string;
  nodeSecondary?: (id: string) => string | undefined;
  nodeDashed?: (id: string) => boolean;
  edgeClass?: (fromId: string, toId: string) => string | undefined;
  selectedJobId?: string | null;
  hoveredJobId?: string | null;
  panX?: number;
  panY?: number;
  zoom?: number;
  height?: number;
  onClickNode?: (id: string) => void;
  onHoverNode?: (id: string) => void;
  onUnhoverNode?: () => void;
  onBackgroundMouseDown?: (e: MouseEvent) => void;
  onWheel?: (deltaY: number, anchorX: number, anchorY: number) => void;
};

const DOT_SPACING = 24;
const DOT_RADIUS = 1;

function truncateName(max: number, name: string): string {
  return name.length > max ? name.slice(0, max - 1) + "…" : name;
}

export function DagGraph(props: DagGraphProps) {
  let containerRef: HTMLDivElement | undefined;
  const [containerW, setContainerW] = createSignal(0);

  onMount(() => {
    if (containerRef) setContainerW(containerRef.clientWidth);
  });

  const px = () => props.panX ?? 0;
  const py = () => props.panY ?? 0;
  const z = () => props.zoom ?? 1;
  const h = () => props.height ?? 600;

  const PAD = 30;

  const centerX = () => {
    const w = containerW();
    if (w === 0 || props.layout.nodes.length === 0) return PAD;
    return Math.max(PAD, (w - props.layout.width) / 2);
  };

  const centerY = () => {
    if (props.layout.nodes.length === 0) return PAD;
    return Math.max(PAD, (h() - props.layout.height) / 2);
  };

  const litSet = createMemo(() => {
    const hovered = props.hoveredJobId;
    const selected = props.selectedJobId;
    if (!hovered && !selected) return new Set<string>();
    const fromHover = hovered ? props.layout.lineageOf(hovered) : new Set<string>();
    const fromSelect = selected ? props.layout.lineageOf(selected) : new Set<string>();
    return new Set([...fromHover, ...fromSelect]);
  });

  const contentTransform = () =>
    `translate(${centerX() + px()} ${centerY() + py()}) scale(${z()})`;

  const dotPatternTransform = () => {
    const modF = (a: number, b: number) => a - b * Math.floor(a / b);
    const totalX = centerX() + px();
    const totalY = centerY() + py();
    return `translate(${modF(totalX, DOT_SPACING)} ${modF(totalY, DOT_SPACING)})`;
  };

  const handleSvgMouseDown = (e: MouseEvent) => {
    if (e.button !== 0) return;
    props.onBackgroundMouseDown?.(e);
  };

  const handleWheel = (e: WheelEvent) => {
    e.preventDefault();
    const rect = containerRef?.getBoundingClientRect();
    if (!rect) return;
    props.onWheel?.(e.deltaY, e.clientX - rect.left - centerX(), e.clientY - rect.top - centerY());
  };

  return (
    <div
      ref={containerRef}
      class="relative overflow-hidden border border-border bg-bg-raise select-none cursor-grab"
      style={{ height: `${h()}px` }}
      on:mousedown={handleSvgMouseDown}
      on:wheel={handleWheel}
    >
      <svg class="block w-full h-full">
        <defs>
          <pattern
            id="dag-dot-pattern"
            width={DOT_SPACING}
            height={DOT_SPACING}
            patternUnits="userSpaceOnUse"
            patternTransform={dotPatternTransform()}
          >
            <circle
              cx={DOT_SPACING / 2}
              cy={DOT_SPACING / 2}
              r={DOT_RADIUS}
              class="dag__dot"
            />
          </pattern>
          <marker
            id="dag-arrow"
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="4"
            orient="auto"
            markerUnits="userSpaceOnUse"
          >
            <path d="M 0 0 L 7 4 L 0 8 Z" class="dag__arrow" />
          </marker>
          <marker
            id="dag-arrow-lit"
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="4"
            orient="auto"
            markerUnits="userSpaceOnUse"
          >
            <path d="M 0 0 L 7 4 L 0 8 Z" class="dag__arrow-lit" />
          </marker>
        </defs>

        <rect x="-100%" y="-100%" width="300%" height="300%" fill="url(#dag-dot-pattern)" />

        <g transform={contentTransform()}>
          <For each={props.layout.edges}>
            {(edge) => (
              <DagEdgeView
                edge={edge}
                litSet={litSet()}
                extraClass={props.edgeClass?.(edge.fromId, edge.toId)}
              />
            )}
          </For>
          <For each={props.layout.nodes}>
            {(pn) => (
              <DagNodeView
                node={pn}
                litSet={litSet()}
                label={props.nodeLabel(pn.id)}
                color={props.nodeColor?.(pn.id)}
                secondary={props.nodeSecondary?.(pn.id)}
                dashed={props.nodeDashed?.(pn.id)}
                onClickNode={props.onClickNode}
                onHoverNode={props.onHoverNode}
                onUnhoverNode={props.onUnhoverNode}
              />
            )}
          </For>
        </g>
      </svg>
    </div>
  );
}

function DagNodeView(props: {
  node: PositionedNode;
  litSet: Set<string>;
  label: string;
  color?: string;
  secondary?: string;
  dashed?: boolean;
  onClickNode?: (id: string) => void;
  onHoverNode?: (id: string) => void;
  onUnhoverNode?: () => void;
}) {
  const pn = () => props.node;
  const tl = () => ({
    x: pn().x - pn().width / 2,
    y: pn().y - pn().height / 2,
  });

  const litClass = () => {
    if (props.litSet.size === 0) return "";
    return props.litSet.has(pn().id) ? " dag__node--lit" : " dag__node--dim";
  };

  const dashedClass = () => (props.dashed ? " dag__node--waiting" : "");

  const handleClick = (e: MouseEvent) => {
    e.stopPropagation();
    props.onClickNode?.(pn().id);
  };

  const handleMouseDown = (e: MouseEvent) => {
    e.stopPropagation();
  };

  return (
    <g
      class={`dag__node${dashedClass()}${litClass()}`}
      data-node-id={pn().id}
      onClick={handleClick}
      onMouseOver={() => props.onHoverNode?.(pn().id)}
      onMouseOut={() => props.onUnhoverNode?.()}
      on:mousedown={handleMouseDown}
      style={{ cursor: "pointer" }}
    >
      <rect
        class="dag__node-bg"
        x={tl().x}
        y={tl().y}
        width={pn().width}
        height={pn().height}
      />
      <Show when={props.color}>
        <rect
          x={tl().x}
          y={tl().y}
          width={3}
          height={pn().height}
          fill={props.color}
        />
      </Show>
      <text
        class="dag__node-name"
        x={tl().x + 12}
        y={tl().y + (props.secondary ? 16 : pn().height / 2)}
        dominant-baseline="middle"
      >
        {truncateName(16, props.label)}
      </text>
      <Show when={props.secondary}>
        <text
          class="dag__node-duration"
          x={tl().x + 12}
          y={tl().y + 32}
          dominant-baseline="middle"
        >
          {props.secondary}
        </text>
      </Show>
    </g>
  );
}

function DagEdgeView(props: {
  edge: DagEdge;
  litSet: Set<string>;
  extraClass?: string;
}) {
  const bothLit = () =>
    props.litSet.has(props.edge.fromId) && props.litSet.has(props.edge.toId);

  const litClass = () => {
    if (props.litSet.size === 0) return "";
    return bothLit() ? " dag__edge--lit" : " dag__edge--dim";
  };

  const marker = () => (bothLit() ? "url(#dag-arrow-lit)" : "url(#dag-arrow)");

  const cls = () => {
    let c = `dag__edge${litClass()}`;
    if (props.extraClass) c += ` ${props.extraClass}`;
    return c;
  };

  return (
    <path
      class={cls()}
      d={edgePath(props.edge)}
      marker-end={marker()}
    />
  );
}
