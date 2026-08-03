/* @refresh reload */
import { createSignal, createMemo, Show, For } from "solid-js";
import { useParams, useNavigate } from "@solidjs/router";
import { Table, type Column } from "../components/Table";
import { StatusBadge } from "../components/StatusBadge";
import { TriggerBadge } from "../components/TriggerBadge";
import { Breadcrumb } from "../components/Breadcrumb";
import { RefBadge } from "../components/RefBadge";
import { useOrgSlug } from "../auth/context";
import {
  usePipeline,
  usePipelineBuilds,
} from "../pipelines/queries";
import { buildStateToVariant, buildStateToLabel } from "../pipelines/status";
import { shortRepoName } from "../pipelines/format";
import { TimeAgo } from "../components/TimeAgo";
import { QueryGuard } from "../components/QueryGuard";
import { DurationCell } from "../components/DurationCell";
import { Dash } from "../components/Dash";
import { CommitHash } from "../components/CommitHash";
import { EmptyMessage } from "../components/EmptyMessage";
import type { components } from "../api/v1";

type BuildResponse = components["schemas"]["Build"];
type BuildState = NonNullable<components["schemas"]["Build"]["state"]>;

type StatusFilter = BuildState | "all";

const FILTERS: { label: string; value: StatusFilter }[] = [
  { label: "All", value: "all" },
  { label: "Running", value: "running" },
  { label: "Passed", value: "passed" },
  { label: "Failed", value: "failed" },
  { label: "Scheduled", value: "scheduled" },
];

const columns: Column<BuildResponse>[] = [
  {
    key: "number",
    label: "#",
    render: (run) => (
      <span class="font-mono text-xs text-fg">#{run.number}</span>
    ),
  },
  {
    key: "status",
    label: "Status",
    render: (run) => (
      <StatusBadge
        text={buildStateToLabel(run.state)}
        variant={buildStateToVariant(run.state)}
        pulse={run.state === "running"}
      />
    ),
  },
  {
    key: "ref",
    label: "Ref",
    render: (run) => (
      <Show when={run.branch} fallback={<Dash />}>
        {(branch) => (
          <RefBadge>{branch()}</RefBadge>
        )}
      </Show>
    ),
  },
  {
    key: "commit",
    label: "Commit",
    render: (run) => (
      <Show when={run.commit} fallback={<Dash />}>
        {(sha) => <CommitHash sha={sha()} />}
      </Show>
    ),
  },
  {
    key: "trigger",
    label: "Trigger",
    render: (run) => <TriggerBadge source={run.source} />,
  },
  {
    key: "duration",
    label: "Duration",
    align: "right",
    render: (run) => (
      <DurationCell startedAt={run.started_at} finishedAt={run.finished_at} />
    ),
  },
  {
    key: "started",
    label: "Started",
    align: "right",
    render: (run) => <TimeAgo date={run.created_at} />,
  },
];

export function PipelineDetailPage() {
  const params = useParams<{ slug: string }>();
  const navigate = useNavigate();
  const orgSlug = useOrgSlug();
  const pipelineSlug = () => params.slug;
  const pipeline = usePipeline(orgSlug, pipelineSlug);
  const builds = usePipelineBuilds(orgSlug, pipelineSlug);

  const [filter, setFilter] = createSignal<StatusFilter>("all");

  const filtered = createMemo(() => {
    const all = builds.data ?? [];
    const f = filter();
    if (f === "all") return all;
    return all.filter((r) => r.state === f);
  });

  return (
    <div>
      <Breadcrumb
        crumbs={[
          { label: "Pipelines", href: `/${orgSlug()}/pipelines` },
          { label: pipeline.data?.name ?? pipelineSlug() },
        ]}
      />

      <div class="flex items-center justify-between gap-4 mb-1">
        <h1 class="text-xl font-semibold text-fg">
          <Show when={shortRepoName(pipeline.data?.repo_name)}>
            {(r) => <span class="text-fg-muted">{r()}/</span>}
          </Show>
          {pipeline.data?.name ?? pipelineSlug()}
        </h1>
      </div>

      <Show when={pipeline.data?.repository}>
        {(repo) => (
          <p class="font-mono text-xs text-fg-muted mb-4">{repo()}</p>
        )}
      </Show>

      <div class="flex items-center gap-1 mb-4">
        <For each={FILTERS}>
          {(f) => (
            <button
              class={`px-3 py-1 font-mono text-xs rounded-[2px] cursor-pointer border ${
                filter() === f.value
                  ? "border-accent text-fg bg-accent/10"
                  : "border-transparent text-fg-muted hover:text-fg hover:bg-bg-hover"
              }`}
              onClick={() => setFilter(f.value)}
            >
              {f.label}
            </button>
          )}
        </For>
      </div>

      <QueryGuard query={builds} loadingRows={5}>
        <Show
          when={filtered().length > 0}
          fallback={<EmptyMessage>No runs</EmptyMessage>}
        >
          <Table
            columns={columns}
            rows={filtered()}
            onRowClick={(run) =>
              navigate(`/${orgSlug()}/pipelines/${pipelineSlug()}/builds/${run.number}`)
            }
          />
        </Show>
      </QueryGuard>
    </div>
  );
}

