/**
 * End-to-end harness: push ANY local repo to a running Harmont backend and run
 * its pipeline to completion. No GitHub involved.
 *
 * Also the canonical usage example for the PURE generated SDK — it shows every
 * manual step a consumer must do (tar -> base64 -> createBuild -> poll -> SSE),
 * because the SDK intentionally ships no convenience wrapper.
 *
 * Gating (mirrors the Freestyle/Runloop integration tests):
 *   HARMONT_E2E=1                required, else this no-ops (exit 0)
 *   HARMONT_API_URL              e.g. http://localhost:4000 or https://api.harmont.dev
 *   HARMONT_TOKEN                a bearer token (dev seed: hmt_localdev_devseed)
 *   HARMONT_ORG                  optional; defaults to the token's first org
 *   HARMONT_REPO_DIR             optional; defaults to e2e/fixtures/hello
 *   HARMONT_E2E_EXPECT_SOURCE=1  optional; assert pushed files reached the cmd
 *                                (real-VM backend only)
 *   HARMONT_E2E_LOGS=1           optional; stream SSE logs after completion
 */
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { create as tarCreate } from "tar";
import { createClient, createConfig } from "../src/generated/client/index.ts";
import {
  createPipeline,
  createBuild,
  getBuild,
  listOrganizations,
  getBuildLogToken,
  listJobs,
} from "../src/generated/index.ts";
import { isTerminal, defaultIr } from "./lib.ts";

const here = dirname(fileURLToPath(import.meta.url));

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) {
    throw new Error(`Missing required env var ${name}`);
  }
  return v;
}

async function main(): Promise<void> {
  if (process.env.HARMONT_E2E !== "1") {
    console.log("HARMONT_E2E != 1 — skipping e2e (set HARMONT_E2E=1 to run).");
    return;
  }

  const baseUrl = env("HARMONT_API_URL");
  const token = env("HARMONT_TOKEN");
  const repoDir = env("HARMONT_REPO_DIR", join(here, "fixtures/hello"));
  const expectSource = process.env.HARMONT_E2E_EXPECT_SOURCE === "1";

  // 1. Construct the SDK client and attach the bearer token.
  const client = createClient(createConfig({ baseUrl }));
  client.interceptors.request.use((req) => {
    req.headers.set("Authorization", `Bearer ${token}`);
    return req;
  });

  // 2. Resolve the org slug.
  const orgs = await listOrganizations({ client });
  if (orgs.error) {
    throw new Error(`listOrganizations failed: ${JSON.stringify(orgs.error)}`);
  }
  const orgSlug = process.env.HARMONT_ORG ?? orgs.data?.data?.[0]?.slug;
  if (!orgSlug) throw new Error("No organization available for this token.");
  console.log(`org: ${orgSlug}`);

  // 3. Create a fresh pipeline (non-GitHub: repository is a free string).
  const name = `e2e-${Date.now()}`;
  const pipe = await createPipeline({
    client,
    path: { org: orgSlug },
    body: { name, repository: "local/e2e", default_branch: "main" },
  });
  if (pipe.error) {
    throw new Error(`createPipeline failed: ${JSON.stringify(pipe.error)}`);
  }
  const pipelineSlug = pipe.data!.slug;
  console.log(`pipeline: ${pipelineSlug}`);

  // 4. Tar+gzip the repo and base64-encode it (the hm-run upload path).
  const tgz = join(mkdtempSync(join(tmpdir(), "hm-e2e-")), "source.tgz");
  await tarCreate({ gzip: true, file: tgz, cwd: repoDir }, ["."]);
  const sourceB64 = readFileSync(tgz).toString("base64");
  console.log(`source: ${repoDir} (${sourceB64.length} b64 chars)`);

  // 5. Create the build with the pushed source + a pre-rendered v0 IR.
  const created = await createBuild({
    client,
    path: { org: orgSlug, pipeline: pipelineSlug },
    body: {
      branch: "main",
      commit: "0000000000000000000000000000000000000000",
      source: "api",
      source_b64: sourceB64,
      pipeline_ir: defaultIr(expectSource),
    },
  });
  if (created.error) {
    throw new Error(`createBuild failed: ${JSON.stringify(created.error)}`);
  }
  const number = created.data!.number;
  console.log(`build #${number} created (state=${created.data!.state})`);

  // 6. Poll to a terminal state.
  const finalState = await pollBuild(client, orgSlug, pipelineSlug, number);
  console.log(`build #${number} finished: ${finalState}`);

  // 7. (optional) Stream logs — hand-rolled because the SSE endpoint is not in
  //    the SDK (it lives at GET /v0/jobs/:id/logs, outside /api/v0).
  if (process.env.HARMONT_E2E_LOGS === "1") {
    await streamLogs(client, baseUrl, orgSlug, pipelineSlug, number);
  }

  if (finalState !== "passed") {
    throw new Error(`Expected build to pass, got "${finalState}".`);
  }
  console.log("E2E PASSED");
}

async function pollBuild(
  client: ReturnType<typeof createClient>,
  org: string,
  pipeline: string,
  number: number,
): Promise<string> {
  const deadline = Date.now() + 5 * 60_000; // 5 min
  while (Date.now() < deadline) {
    const res = await getBuild({ client, path: { org, pipeline, number } });
    if (res.error) throw new Error(`getBuild failed: ${JSON.stringify(res.error)}`);
    const state = res.data!.state;
    process.stdout.write(`  state=${state}\n`);
    if (isTerminal(state)) return state;
    await sleep(2000);
  }
  throw new Error("Timed out waiting for the build to reach a terminal state.");
}

async function streamLogs(
  client: ReturnType<typeof createClient>,
  baseUrl: string,
  org: string,
  pipeline: string,
  number: number,
): Promise<void> {
  const tok = await getBuildLogToken({ client, path: { org, pipeline, number } });
  if (tok.error) {
    console.warn(`log token unavailable: ${JSON.stringify(tok.error)}`);
    return;
  }
  const jobs = await listJobs({ client, path: { org, pipeline, number } });
  if (jobs.error) return;
  for (const job of jobs.data?.data ?? []) {
    // The SSE endpoint lives OUTSIDE /api/v0 and is not in openapi.json.
    const origin = new URL(baseUrl).origin;
    const url = `${origin}/v0/jobs/${job.id}/logs?token=${encodeURIComponent(tok.data!.token)}`;
    const resp = await fetch(url, { headers: { Accept: "text/event-stream" } });
    if (!resp.ok || !resp.body) continue;
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      process.stdout.write(text);
      if (text.includes("event: done")) break;
    }
    await reader.cancel();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
