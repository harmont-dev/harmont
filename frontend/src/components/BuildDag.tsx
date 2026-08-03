import { createMemo } from "solid-js";
import { DagGraph } from "./DagGraph";
import { layoutDag } from "../dag/layout";
import { statusColor } from "../dag/status-colors";
import { usePanZoom } from "../dag/usePanZoom";
import { fmtDuration } from "../format/duration";
import type { components } from "../api/v1";

type JobResponse = components["schemas"]["Job"];

export function BuildDag(props: {
  jobs: JobResponse[];
  selectedJobId?: string | null;
  hoveredJobId?: string | null;
  onClickJob?: (id: string) => void;
  onHoverJob?: (id: string) => void;
  onUnhoverJob?: () => void;
  height?: number;
}) {
  const pz = usePanZoom();

  const jobsById = createMemo(() => {
    const map = new Map<string, JobResponse>();
    for (const j of props.jobs) map.set(j.id, j);
    return map;
  });

  const dagLayout = createMemo(() =>
    layoutDag(
      props.jobs.map((j) => ({
        id: j.id,
        depends_on: j.depends_on,
      })),
    ),
  );

  // Prefer the human name, then the step key (the DAG key the user wrote);
  // only fall back to the raw uuid as a last resort.
  const nodeLabel = (id: string) => {
    const j = jobsById().get(id);
    return j?.name || j?.step_key || id;
  };

  const nodeColor = (id: string) => {
    const job = jobsById().get(id);
    return job ? statusColor(job.state) : "var(--color-status-queued)";
  };

  const nodeSecondary = (id: string) => {
    const job = jobsById().get(id);
    if (!job?.started_at || !job?.finished_at) return undefined;
    return fmtDuration(job.started_at, job.finished_at);
  };

  const nodeDashed = (id: string) => {
    const job = jobsById().get(id);
    return (
      job?.state === "pending" ||
      job?.state === "scheduled" ||
      job?.state === "assigned"
    );
  };

  return (
    <DagGraph
      layout={dagLayout()}
      nodeLabel={nodeLabel}
      nodeColor={nodeColor}
      nodeSecondary={nodeSecondary}
      nodeDashed={nodeDashed}
      selectedJobId={props.selectedJobId}
      hoveredJobId={props.hoveredJobId}
      panX={pz.panX()}
      panY={pz.panY()}
      zoom={pz.zoom()}
      height={props.height ?? 300}
      onClickNode={props.onClickJob}
      onHoverNode={props.onHoverJob}
      onUnhoverNode={props.onUnhoverJob}
      onBackgroundMouseDown={pz.onPanStart}
      onWheel={pz.onWheel}
    />
  );
}
