import { http, HttpResponse } from "msw";
import { mockInstallations, mockRepos } from "../data";

const BASE = "/api/v0";

const json = (body: Record<string, unknown> | Record<string, unknown>[]) =>
  HttpResponse.json(body, {
    headers: { "Content-Type": "application/json;charset=utf-8" },
  });

export const githubHandlers = [
  http.get(
    `${BASE}/organizations/:orgSlug/github/installations`,
    async () => {
      return json({ data: mockInstallations });
    },
  ),

  http.get(
    `${BASE}/organizations/:orgSlug/github/installations/:installationId/repos`,
    async ({ params }) => {
      const instId = Number(params.installationId);
      const repos = mockRepos[instId] ?? [];
      return json({ data: repos });
    },
  ),

  http.post(
    `${BASE}/organizations/:orgSlug/github/installations/:installationId/sync`,
    async ({ params }) => {
      const instId = Number(params.installationId);
      const inst = mockInstallations.find(
        (i) => i.installation_id === instId,
      );
      if (!inst) return new HttpResponse(null, { status: 404 });
      return json(inst);
    },
  ),

  http.delete(
    `${BASE}/organizations/:orgSlug/github/installations/:installationId`,
    async () => {
      return new HttpResponse(null, { status: 204 });
    },
  ),
];
