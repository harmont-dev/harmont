import {
  createMutation,
  createQueries,
  createQuery,
  useQueryClient,
} from "@tanstack/solid-query";
import { createMemo } from "solid-js";
import { createApiClient } from "../api/client";
import type { components } from "../api/v1";
import { isBuildTerminal, isJobTerminal } from "./status";

export const PIPELINE_KEYS = {
  list: (orgSlug: string) => ["pipelines", orgSlug] as const,
  detail: (orgSlug: string, slug: string) =>
    ["pipelines", orgSlug, slug] as const,
  builds: (orgSlug: string, slug: string) =>
    ["pipelines", orgSlug, slug, "builds"] as const,
  build: (orgSlug: string, slug: string, num: number) =>
    ["pipelines", orgSlug, slug, "builds", num] as const,
  jobs: (orgSlug: string, slug: string, num: number) =>
    ["pipelines", orgSlug, slug, "builds", num, "jobs"] as const,
};

export function usePipelines(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...PIPELINE_KEYS.list(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function usePipeline(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
) {
  return createQuery(() => ({
    queryKey: [...PIPELINE_KEYS.detail(orgSlug()!, pipelineSlug())],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines/{pipeline}",
        {
          params: {
            path: { org: orgSlug()!, pipeline: pipelineSlug() },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function usePipelineBuilds(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
) {
  return createQuery(() => ({
    queryKey: [...PIPELINE_KEYS.builds(orgSlug()!, pipelineSlug())],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines/{pipeline}/builds",
        {
          params: {
            path: { org: orgSlug()!, pipeline: pipelineSlug() },
          },
        },
      );
      if (error) throw error;
      // Return the builds array, NOT the `{ data, next_cursor }` envelope:
      // `useAllPipelineBuilds` (the dashboard) writes the SAME builds cache key
      // with the unwrapped array, so this MUST match or a dashboard-prefetched
      // entry is read here as the wrong shape — manifesting as "No runs" until a
      // hard refresh. Keep both queries' return shapes identical.
      return data!.data;
    },
    enabled: !!orgSlug(),
  }));
}

export function useBuild(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
  buildNumber: () => number,
  opts?: { poll?: boolean },
) {
  return createQuery(() => ({
    queryKey: [
      ...PIPELINE_KEYS.build(orgSlug()!, pipelineSlug(), buildNumber()),
    ],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}",
        {
          params: {
            path: {
              org: orgSlug()!,
              pipeline: pipelineSlug(),
              number: buildNumber(),
            },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
    refetchInterval: opts?.poll
      ? (query) => {
          const state = query.state.data?.state;
          if (!state || !isBuildTerminal(state)) return 2000;
          return false;
        }
      : undefined,
  }));
}

export function useBuildJobs(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
  buildNumber: () => number,
  opts?: { poll?: boolean },
) {
  return createQuery(() => ({
    queryKey: [
      ...PIPELINE_KEYS.jobs(orgSlug()!, pipelineSlug(), buildNumber()),
    ],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/jobs",
        {
          params: {
            path: {
              org: orgSlug()!,
              pipeline: pipelineSlug(),
              number: buildNumber(),
            },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
    // Stop polling once every job is terminal — like `useBuild`, an
    // already-finished build never changes, so a forever-2s poll is wasted
    // work. Keep polling while jobs are still loading or any job is live.
    refetchInterval: opts?.poll
      ? (query) => {
          const jobs = query.state.data?.data;
          if (!jobs || jobs.length === 0) return 2000;
          return jobs.every((j) => isJobTerminal(j.state)) ? false : 2000;
        }
      : undefined,
  }));
}

type BuildResponse = components["schemas"]["Build"];

export function useAllPipelineBuilds(
  orgSlug: () => string | undefined,
  slugs: () => string[],
): () => Record<string, BuildResponse[]> {
  // One managed query per pipeline. TanStack dedupes by key, cancels stale
  // in-flight fetches when the slug list changes, and surfaces errors — none
  // of which the old fire-and-forget `createEffect` + `.then()` loop did (it
  // raced stale writes and silently swallowed failures).
  const pipeSlugs = createMemo(() => (orgSlug() ? slugs() : []));

  const results = createQueries(() => ({
    queries: pipeSlugs().map((slug) => ({
      queryKey: [...PIPELINE_KEYS.builds(orgSlug()!, slug)],
      queryFn: async () => {
        const client = createApiClient();
        const { data, error } = await client.GET(
          "/api/v0/organizations/{org}/pipelines/{pipeline}/builds",
          { params: { path: { org: orgSlug()!, pipeline: slug } } },
        );
        if (error) throw error;
        return data!.data;
      },
    })),
  }));

  // Fold the per-pipeline results back into the `{ slug: builds }` map the
  // dashboard consumes. The results array mirrors `pipeSlugs()` order (both
  // derive from the same reactive source), so a positional correlation is
  // stable; a missing/errored pipeline just yields no entry.
  return createMemo(() => {
    const map: Record<string, BuildResponse[]> = {};
    const list = pipeSlugs();
    results.forEach((q, i) => {
      const slug = list[i];
      if (slug && q.data) map[slug] = q.data;
    });
    return map;
  });
}

export function useCancelBuild(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
  buildNumber: () => number,
) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.PUT(
        "/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/cancel",
        {
          params: {
            path: {
              org: orgSlug()!,
              pipeline: pipelineSlug(),
              number: buildNumber(),
            },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    onSuccess: (build) => {
      // Reflect the new state immediately, then refresh the build + its jobs
      // (cancel transitions non-terminal jobs server-side).
      qc.setQueryData(
        [...PIPELINE_KEYS.build(orgSlug()!, pipelineSlug(), buildNumber())],
        build,
      );
      qc.invalidateQueries({
        queryKey: [
          ...PIPELINE_KEYS.build(orgSlug()!, pipelineSlug(), buildNumber()),
        ],
      });
      qc.invalidateQueries({
        queryKey: [
          ...PIPELINE_KEYS.jobs(orgSlug()!, pipelineSlug(), buildNumber()),
        ],
      });
    },
  }));
}

export function useLogToken(
  orgSlug: () => string | undefined,
  pipelineSlug: () => string,
  buildNumber: () => number,
) {
  return createQuery(() => ({
    queryKey: ["logToken", orgSlug()!, pipelineSlug(), buildNumber()] as const,
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/log-token",
        {
          params: {
            path: {
              org: orgSlug()!,
              pipeline: pipelineSlug(),
              number: buildNumber(),
            },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
    staleTime: 4 * 60 * 1000,
  }));
}

