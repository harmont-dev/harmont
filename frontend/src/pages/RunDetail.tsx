/* @refresh reload */
import { createSignal, Show } from "solid-js";
import { useParams } from "@solidjs/router";
import { Table, type Column } from "../components/Table";
import { StatusBadge } from "../components/StatusBadge";
import { TriggerBadge } from "../components/TriggerBadge";
import { Breadcrumb } from "../components/Breadcrumb";
import { Button } from "../components/Button";
import { RefBadge } from "../components/RefBadge";
import { useOrgSlug } from "../auth/context";
import {
  usePipeline,
  useBuild,
  useBuildJobs,
  useLogToken,
  useCancelBuild,
} from "../pipelines/queries";
import { useLogStream } from "../logs/useLogStream";
import { LogViewer } from "../components/LogViewer";
import {
  buildStateToVariant,
  buildStateToLabel,
  jobStateToVariant,
  jobStateToLabel,
} from "../pipelines/status";
import { SectionHeading } from "../components/SectionHeading";
import { LoadingSkeleton } from "../components/LoadingSkeleton";
import { QueryError } from "../components/QueryError";
import { ErrorBanner } from "../components/ErrorBanner";
import { apiErrorMessage } from "../api/errors";
import { TimeAgo } from "../components/TimeAgo";
import { DurationCell } from "../components/DurationCell";
import { CommitHash } from "../components/CommitHash";
import { EmptyMessage } from "../components/EmptyMessage";
import { BuildDag } from "../components/BuildDag";
import { fmtDuration } from "../format/duration";
import type { components } from "../api/v1";

type JobResponse = components["schemas"]["Job"];

const jobColumns: Column<JobResponse>[] = [
  {
    key: "name",
    label: "Name",
    render: (job) => (
      <div>
        <span class="text-fg font-medium">{job.name || job.step_key}</span>
        <Show when={job.state === "failed" && job.error_message}>
          <div class="text-xs text-status-failed mt-0.5 truncate max-w-[300px]" title={job.error_message!}>
            {job.error_message}
          </div>
        </Show>
      </div>
    ),
  },
  {
    key: "status",
    label: "Status",
    render: (job) => (
      <div class="flex items-center gap-2">
        <StatusBadge
          text={jobStateToLabel(job.state)}
          variant={jobStateToVariant(job.state)}
          pulse={job.state === "running"}
        />
        <Show when={job.state === "failed" && job.error_code}>
          <code class="font-mono text-2xs text-status-failed">{job.error_code}</code>
        </Show>
      </div>
    ),
  },
  {
    key: "duration",
    label: "Duration",
    align: "right",
    render: (job) => (
      <DurationCell startedAt={job.started_at} finishedAt={job.finished_at} />
    ),
  },
  {
    key: "exit",
    label: "Exit",
    align: "right",
    render: (job) => (
      <code class="font-mono text-xs text-fg-dim">
        {job.exit_code != null ? job.exit_code : "—"}
      </code>
    ),
  },
];

export function RunDetailPage() {
  const params = useParams<{ slug: string; number: string }>();
  const orgSlug = useOrgSlug();
  const pipelineSlug = () => params.slug;
  const buildNumber = () => Number(params.number);
  const pipeline = usePipeline(orgSlug, pipelineSlug);
  const build = useBuild(orgSlug, pipelineSlug, buildNumber, { poll: true });
  const jobs = useBuildJobs(orgSlug, pipelineSlug, buildNumber, { poll: true });
  const cancelBuild = useCancelBuild(orgSlug, pipelineSlug, buildNumber);

  const [selectedJobId, setSelectedJobId] = createSignal<string | null>(null);
  const [hoveredJobId, setHoveredJobId] = createSignal<string | null>(null);

  const logToken = useLogToken(orgSlug, pipelineSlug, buildNumber);
  const apiUrl = () => import.meta.env.VITE_API_URL ?? "";
  const logStream = useLogStream(
    () => selectedJobId() ?? undefined,
    () => logToken.data?.token,
    apiUrl,
  );

  const selectedJob = () => {
    const id = selectedJobId();
    if (!id) return undefined;
    return (jobs.data?.data ?? []).find((j) => j.id === id);
  };

  return (
    <div>
      <Breadcrumb
        crumbs={[
          { label: "Pipelines", href: `/${orgSlug()}/pipelines` },
          {
            label: pipeline.data?.name ?? pipelineSlug(),
            href: `/${orgSlug()}/pipelines/${pipelineSlug()}`,
          },
          { label: `#${buildNumber()}` },
        ]}
      />

      <Show
        when={build.data}
        fallback={
          <Show
            when={build.isError}
            fallback={<LoadingSkeleton rows={1} height={60} />}
          >
            <QueryError error={build.error} />
          </Show>
        }
      >
        {(run) => (
          <>
            <div class="flex items-center gap-3 mb-1">
              <span class="text-xl font-semibold text-fg font-mono">
                #{run().number}
              </span>
              <StatusBadge
                text={buildStateToLabel(run().state)}
                variant={buildStateToVariant(run().state)}
                pulse={run().state === "running"}
              />
            </div>

            <div class="flex items-center gap-3 mb-4 font-mono text-xs text-fg-muted">
              <Show when={run().branch}>
                {(branch) => (
                  <RefBadge>{branch()}</RefBadge>
                )}
              </Show>
              <Show when={run().commit}>
                {(sha) => <CommitHash sha={sha()} />}
              </Show>
              <TriggerBadge source={run().source} />
              <Show when={run().started_at && run().finished_at}>
                <span>{fmtDuration(run().started_at!, run().finished_at!)}</span>
              </Show>
              <TimeAgo date={run().created_at} />
            </div>

            <Show when={run().state === "failed" && run().error_code}>
              <div class="mb-4 p-3 border border-status-failed/30 rounded-[2px] bg-status-failed/5">
                <div class="flex items-center gap-2 mb-1">
                  <span class="font-mono text-xs font-semibold text-status-failed uppercase">
                    Build failed
                  </span>
                  <code class="font-mono text-xs text-status-failed">
                    {run().error_code}
                  </code>
                </div>
                <Show when={run().error_message}>
                  {(msg) => (
                    <pre class="font-mono text-xs text-fg-muted whitespace-pre-wrap">
                      {msg()}
                    </pre>
                  )}
                </Show>
              </div>
            </Show>

            <Show when={run().state === "running" || run().state === "failing"}>
              <div class="mb-4 flex flex-col gap-2">
                <Button
                  variant="danger"
                  size="md"
                  mode={cancelBuild.isPending ? "inactive" : "active"}
                  disabled={cancelBuild.isPending}
                  onClick={() => cancelBuild.mutate()}
                >
                  {cancelBuild.isPending ? "Canceling..." : "Cancel"}
                </Button>
                <Show when={cancelBuild.isError}>
                  <ErrorBanner
                    message={apiErrorMessage(
                      cancelBuild.error,
                      "Could not cancel this build.",
                    )}
                  />
                </Show>
              </div>
            </Show>
          </>
        )}
      </Show>

      <Show
        when={!jobs.isPending && (jobs.data?.data ?? []).length > 0}
      >
        <div class="mb-4">
          <BuildDag
            jobs={jobs.data?.data ?? []}
            selectedJobId={selectedJobId()}
            hoveredJobId={hoveredJobId()}
            onClickJob={(id) =>
              setSelectedJobId((prev) => (prev === id ? null : id))
            }
            onHoverJob={setHoveredJobId}
            onUnhoverJob={() => setHoveredJobId(null)}
          />
        </div>
      </Show>

      <SectionHeading>Jobs</SectionHeading>

      <Show
        when={!jobs.isPending}
        fallback={<LoadingSkeleton rows={3} />}
      >
        <Show when={jobs.isError}>
          <QueryError error={jobs.error} />
        </Show>
        <Show
          when={!jobs.isError && (jobs.data?.data ?? []).length > 0}
          fallback={<Show when={!jobs.isError}><EmptyMessage>No jobs</EmptyMessage></Show>}
        >
          <Table
            columns={jobColumns}
            rows={jobs.data?.data ?? []}
            selectedIndex={(jobs.data?.data ?? []).findIndex(
              (j) => j.id === selectedJobId(),
            )}
            onRowClick={(job) =>
              setSelectedJobId((prev) =>
                prev === job.id ? null : job.id,
              )
            }
          />
        </Show>
      </Show>

      <Show when={selectedJob()}>
        {(job) => (
          <div class="mt-4 p-4 border border-border rounded-[2px] bg-bg-raise">
            <div class="flex items-center justify-between mb-3">
              <div class="flex items-center gap-2">
                <span class="font-mono text-sm font-medium text-fg">
                  {job().name || job().step_key}
                </span>
                <StatusBadge
                  text={jobStateToLabel(job().state)}
                  variant={jobStateToVariant(job().state)}
                  pulse={job().state === "running"}
                />
              </div>
              <Button
                size="md"
                onClick={() => setSelectedJobId(null)}
              >
                Close
              </Button>
            </div>
            <Show when={job().command}>
              {(cmd) => (
                <pre class="font-mono text-xs text-fg-muted bg-bg-inset p-3 rounded-[2px] border border-border mb-3 overflow-x-auto">
                  {cmd()}
                </pre>
              )}
            </Show>
            <Show when={logToken.isError}>
              <div class="mb-3">
                <ErrorBanner
                  message={apiErrorMessage(logToken.error, "Could not load logs")}
                />
              </div>
            </Show>
            <LogViewer state={logStream()} />
          </div>
        )}
      </Show>
    </div>
  );
}
