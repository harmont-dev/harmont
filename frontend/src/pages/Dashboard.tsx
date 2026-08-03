/* @refresh reload */
import { createSignal, createMemo, Show } from "solid-js";
import { useNavigate } from "@solidjs/router";
import { Table, type Column } from "../components/Table";
import { StatusBadge } from "../components/StatusBadge";
import { Sparkline } from "../components/Sparkline";
import { TextInput } from "../components/TextInput";
import { useOrgSlug } from "../auth/context";
import { usePipelines, useAllPipelineBuilds } from "../pipelines/queries";
import { buildStateToVariant, buildStateToLabel } from "../pipelines/status";
import { TimeAgo } from "../components/TimeAgo";
import { QueryGuard } from "../components/QueryGuard";
import { DurationCell } from "../components/DurationCell";
import { Dash } from "../components/Dash";
import { CommitHash } from "../components/CommitHash";
import { EmptyMessage } from "../components/EmptyMessage";
import type { components } from "../api/v1";
import { shortRepoName } from "../pipelines/format";

type PipelineResponse = components["schemas"]["Pipeline"];
type BuildResponse = components["schemas"]["Build"];

type PipelineRow = {
  pipeline: PipelineResponse;
  builds: BuildResponse[];
  latestRun: BuildResponse | undefined;
};

const columns: Column<PipelineRow>[] = [
  {
    key: "pipeline",
    label: "Pipeline",
    render: (row) => {
      const repo = shortRepoName(row.pipeline.repo_name);
      return (
        <span class="text-fg font-medium">
          <Show when={repo}>
            {(r) => <span class="text-fg-muted">{r()}/</span>}
          </Show>
          {row.pipeline.name}
        </span>
      );
    },
  },
  {
    key: "builds",
    label: "Builds",
    render: (row) => <Sparkline builds={row.builds} />,
  },
  {
    key: "status",
    label: "Status",
    render: (row) => (
      <Show
        when={row.latestRun}
        fallback={<Dash />}
      >
        {(run) => (
          <StatusBadge
            text={buildStateToLabel(run().state)}
            variant={buildStateToVariant(run().state)}
            pulse={run().state === "running"}
          />
        )}
      </Show>
    ),
  },
  {
    key: "commit",
    label: "Commit",
    render: (row) => (
      <Show
        when={row.latestRun?.commit}
        fallback={<Dash />}
      >
        {(sha) => <CommitHash sha={sha()} />}
      </Show>
    ),
  },
  {
    key: "duration",
    label: "Duration",
    align: "right",
    render: (row) => (
      <DurationCell startedAt={row.latestRun?.started_at} finishedAt={row.latestRun?.finished_at} />
    ),
  },
  {
    key: "lastRun",
    label: "Last run",
    align: "right",
    render: (row) => (
      <Show
        when={row.latestRun}
        fallback={<Dash />}
      >
        {(run) => <TimeAgo date={run().created_at} />}
      </Show>
    ),
  },
];

export function DashboardPage() {
  const navigate = useNavigate();
  const orgSlug = useOrgSlug();
  const pipelines = usePipelines(orgSlug);
  const pipelineSlugs = () =>
    pipelines.data?.data.map((p) => p.slug) ?? [];
  const buildsMap = useAllPipelineBuilds(orgSlug, pipelineSlugs);
  const [search, setSearch] = createSignal("");

  const rows = createMemo<PipelineRow[]>(() => {
    const data = pipelines.data?.data;
    if (!data) return [];
    const map = buildsMap();
    return data.map((p) => {
      const builds = map[p.slug] ?? [];
      return { pipeline: p, builds, latestRun: builds[0] };
    });
  });

  const filtered = createMemo(() => {
    const q = search().toLowerCase();
    if (!q) return rows();
    return rows().filter((r) =>
      r.pipeline.name.toLowerCase().includes(q),
    );
  });

  return (
    <div>
      <div class="flex items-center justify-between gap-4 mb-5">
        <TextInput
          placeholder="Search pipelines..."
          value={search()}
          onInput={setSearch}
          class="w-64"
        />
      </div>

      <QueryGuard query={pipelines} loadingRows={4}>
        <Show
          when={filtered().length > 0}
          fallback={
            <EmptyMessage>
              {rows().length === 0
                ? "No pipelines yet"
                : "No pipelines found"}
            </EmptyMessage>
          }
        >
          <Table
            columns={columns}
            rows={filtered()}
            onRowClick={(row) =>
              navigate(`/${orgSlug()}/pipelines/${row.pipeline.slug}`)
            }
          />
        </Show>
      </QueryGuard>
    </div>
  );
}

