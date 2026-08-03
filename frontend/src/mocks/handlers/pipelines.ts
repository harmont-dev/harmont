import { http, HttpResponse } from "msw";
import { mockPipelines, mockBuilds, mockJobs } from "../data";

const BASE = "/api/v0";

const json = (body: Record<string, unknown> | Record<string, unknown>[]) =>
  HttpResponse.json(body, {
    headers: { "Content-Type": "application/json;charset=utf-8" },
  });

export const pipelineHandlers = [
  http.get(`${BASE}/organizations/:orgSlug/pipelines`, async () => {
    return json({ data: mockPipelines });
  }),
  http.get(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug`,
    async ({ params }) => {
      const slug = params.pipelineSlug as string;
      const pipeline = mockPipelines.find((p) => p.slug === slug);
      if (!pipeline) return new HttpResponse(null, { status: 404 });
      return json(pipeline);
    },
  ),
  http.get(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug/builds`,
    async ({ params }) => {
      const slug = params.pipelineSlug as string;
      const builds = mockBuilds[slug] ?? [];
      return json({ data: builds });
    },
  ),
  http.post(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug/builds`,
    async ({ params }) => {
      const slug = params.pipelineSlug as string;
      const newBuild = {
        number: (mockBuilds[slug]?.[0]?.number ?? 0) + 1,
        state: "scheduled" as const,
        source: "manual" as const,
        branch: "main",
        commit: "0000000000000000000000000000000000000000",
        message: "Manual trigger",
        created_at: new Date().toISOString(),
      };
      return json(newBuild);
    },
  ),
  http.get(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug/builds/:buildNumber`,
    async ({ params }) => {
      const slug = params.pipelineSlug as string;
      const num = Number(params.buildNumber);
      const build = (mockBuilds[slug] ?? []).find((b) => b.number === num);
      if (!build) return new HttpResponse(null, { status: 404 });
      return json(build);
    },
  ),
  http.get(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug/builds/:buildNumber/jobs`,
    async ({ params }) => {
      const slug = params.pipelineSlug as string;
      const num = Number(params.buildNumber);
      const build = (mockBuilds[slug] ?? []).find((b) => b.number === num);
      if (!build) return json({ data: [] });
      const jobs = mockJobs[`${slug}:${num}`] ?? [];
      return json({ data: jobs });
    },
  ),
  http.get(
    `${BASE}/organizations/:orgSlug/pipelines/:pipelineSlug/builds/:buildNumber/log-token`,
    async () => {
      return json({ token: "mock-log-token", expires_at: Date.now() + 300_000 });
    },
  ),
  http.post(
    `${BASE}/organizations/:orgSlug/github/installations`,
    async ({ request }) => {
      const body = await request.json() as { installation_id: number };
      return json({
        id: body.installation_id,
        account_login: "harmont",
        account_type: "Organization",
        created_at: new Date().toISOString(),
      });
    },
  ),
];
