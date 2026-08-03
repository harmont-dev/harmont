/**
 * Prod smoke tests: one named pass/fail per core SDK capability.
 *
 * The monolithic `e2e/run.ts` harness proves the full flow in one shot; this
 * file repackages the SAME proven sequence as discrete `node:test` subtests so
 * the runner prints a green/red line per capability — "did create-pipeline
 * work? did the build run? did logs stream?".
 *
 * Runs ONLY when all three are set (otherwise the whole block is skipped, so a
 * bare `npm test` stays green):
 *   HARMONT_E2E=1
 *   HARMONT_API_URL   e.g. https://api.harmont.dev
 *   HARMONT_TOKEN     a bearer token for that backend
 * Optional:
 *   HARMONT_ORG            pin the org slug (default: the token's first org)
 *   HARMONT_E2E_TIMEOUT_MS build-poll budget in ms (default: 300000 = 5 min)
 *
 * Run just these:  HARMONT_E2E=1 HARMONT_API_URL=… HARMONT_TOKEN=… npm run test:prod
 */
import { test, before, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { create as tarCreate } from "tar";
import { isTerminal, defaultIr } from "./lib.ts";

const here = dirname(fileURLToPath(import.meta.url));

// The generated surface is a gitignored build artifact; a static import of the
// public entry (which re-exports it) would throw at load even when skipped, so
// we dynamic-import inside `before()` and guard on its existence here.
const generatedExists = existsSync(
  fileURLToPath(new URL("../src/generated/index.ts", import.meta.url)),
);
const configured =
  process.env.HARMONT_E2E === "1" &&
  !!process.env.HARMONT_API_URL &&
  !!process.env.HARMONT_TOKEN;
const skip: false | string = !generatedExists
  ? "run `npm run codegen` first"
  : !configured
    ? "set HARMONT_E2E=1 + HARMONT_API_URL + HARMONT_TOKEN to run prod smoke tests"
    : false;

// Shared, mutable context threaded across the ordered subtests below. `sdk` is
// the dynamically-imported module; the rest are produced step by step.
interface Ctx {
  sdk: typeof import("../src/index.ts");
  client: ReturnType<(typeof import("../src/index.ts"))["createClient"]>;
  org: string;
  pipeline: string;
  build: number;
}
const ctx = {} as Ctx;

describe("prod smoke: core SDK flows", { skip }, () => {
  before(async () => {
    ctx.sdk = await import("../src/index.ts");
    ctx.client = ctx.sdk.createClient(
      ctx.sdk.createConfig({ baseUrl: process.env.HARMONT_API_URL! }),
    );
    ctx.client.interceptors.request.use((req) => {
      req.headers.set("Authorization", `Bearer ${process.env.HARMONT_TOKEN}`);
      return req;
    });
  });

  test("auth: token resolves an organization", async () => {
    const orgs = await ctx.sdk.listOrganizations({ client: ctx.client });
    assert.equal(
      orgs.error,
      undefined,
      `listOrganizations failed: ${JSON.stringify(orgs.error)}`,
    );
    const slug = process.env.HARMONT_ORG ?? orgs.data?.data?.[0]?.slug;
    assert.ok(slug, "no organization available for this token");
    ctx.org = slug;
  });

  test("create a pipeline", async () => {
    assert.ok(ctx.org, "precondition failed: no org from the auth step");
    const name = `e2e-smoke-${Date.now()}`;
    const pipe = await ctx.sdk.createPipeline({
      client: ctx.client,
      path: { org: ctx.org },
      body: { name, repository: "local/e2e", default_branch: "main" },
    });
    assert.equal(
      pipe.error,
      undefined,
      `createPipeline failed: ${JSON.stringify(pipe.error)}`,
    );
    assert.ok(pipe.data?.slug, "createPipeline returned no slug");
    ctx.pipeline = pipe.data.slug;
  });

  test("submit local code and create a build", async () => {
    assert.ok(ctx.pipeline, "precondition failed: no pipeline");
    // tar+gzip the fixture and base64-encode it — the hm-run local upload path.
    const repoDir = process.env.HARMONT_REPO_DIR ?? join(here, "fixtures/hello");
    const tgz = join(mkdtempSync(join(tmpdir(), "hm-smoke-")), "source.tgz");
    await tarCreate({ gzip: true, file: tgz, cwd: repoDir }, ["."]);
    const sourceB64 = readFileSync(tgz).toString("base64");
    assert.ok(sourceB64.length > 0, "encoded source archive is empty");

    const created = await ctx.sdk.createBuild({
      client: ctx.client,
      path: { org: ctx.org, pipeline: ctx.pipeline },
      body: {
        branch: "main",
        commit: "0000000000000000000000000000000000000000",
        source: "api",
        source_b64: sourceB64,
        // defaultIr(false) → `echo harmont-e2e-ok`: source-independent, so the
        // build passes regardless of whether the backend extracts the tarball.
        pipeline_ir: defaultIr(false),
      },
    });
    assert.equal(
      created.error,
      undefined,
      `createBuild failed: ${JSON.stringify(created.error)}`,
    );
    assert.ok(
      typeof created.data?.number === "number",
      "createBuild returned no build number",
    );
    ctx.build = created.data.number;
  });

  test("build runs to a passed state", async () => {
    assert.ok(typeof ctx.build === "number", "precondition failed: no build");
    const budgetMs = Number(process.env.HARMONT_E2E_TIMEOUT_MS ?? 300_000);
    const deadline = Date.now() + budgetMs;
    let state = "scheduled";
    while (Date.now() < deadline) {
      const res = await ctx.sdk.getBuild({
        client: ctx.client,
        path: { org: ctx.org, pipeline: ctx.pipeline, number: ctx.build },
      });
      assert.equal(
        res.error,
        undefined,
        `getBuild failed: ${JSON.stringify(res.error)}`,
      );
      state = res.data!.state;
      if (isTerminal(state)) break;
      await sleep(2000);
    }
    assert.ok(
      isTerminal(state),
      `build #${ctx.build} did not finish within ${budgetMs}ms (last state=${state})`,
    );
    assert.equal(state, "passed", `expected build to pass, got "${state}"`);
  });

  test("read jobs for the build", async () => {
    assert.ok(typeof ctx.build === "number", "precondition failed: no build");
    const jobs = await ctx.sdk.listJobs({
      client: ctx.client,
      path: { org: ctx.org, pipeline: ctx.pipeline, number: ctx.build },
    });
    assert.equal(
      jobs.error,
      undefined,
      `listJobs failed: ${JSON.stringify(jobs.error)}`,
    );
    const list = jobs.data?.data ?? [];
    assert.ok(list.length >= 1, "build produced no jobs");
    // The single echo step must have exited cleanly.
    assert.ok(
      list.some((j) => j.state === "passed" && j.exit_code === 0),
      `no passed job with exit_code 0: ${JSON.stringify(list.map((j) => ({ s: j.state, e: j.exit_code })))}`,
    );
  });

  test("read job logs over SSE", async () => {
    assert.ok(typeof ctx.build === "number", "precondition failed: no build");
    // Mint a build-scoped log token (in the SDK), then hit the SSE endpoint
    // directly — it lives at /v0/jobs/:id/logs, OUTSIDE /api/v0, so it is not
    // part of the generated SDK surface.
    const tok = await ctx.sdk.getBuildLogToken({
      client: ctx.client,
      path: { org: ctx.org, pipeline: ctx.pipeline, number: ctx.build },
    });
    assert.equal(
      tok.error,
      undefined,
      `getBuildLogToken failed: ${JSON.stringify(tok.error)}`,
    );
    const token = tok.data!.token;

    const jobs = await ctx.sdk.listJobs({
      client: ctx.client,
      path: { org: ctx.org, pipeline: ctx.pipeline, number: ctx.build },
    });
    assert.equal(
      jobs.error,
      undefined,
      `listJobs (for SSE) failed: ${JSON.stringify(jobs.error)}`,
    );
    const origin = new URL(process.env.HARMONT_API_URL!).origin;
    let combined = "";
    for (const job of jobs.data?.data ?? []) {
      const url = `${origin}/v0/jobs/${job.id}/logs?token=${encodeURIComponent(token)}`;
      const resp = await fetch(url, { headers: { Accept: "text/event-stream" } });
      if (!resp.ok || !resp.body) continue;
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        combined += decoder.decode(value, { stream: true });
        // Test the rolling buffer, not the chunk — the `event: done` sentinel
        // can be split across two reads.
        if (combined.includes("event: done")) break;
      }
      await reader.cancel();
    }
    // defaultIr(false) runs `echo harmont-e2e-ok`; its stdout must reach the log
    // stream end to end.
    assert.match(
      combined,
      /harmont-e2e-ok/,
      "log stream did not contain the expected command output",
    );
  });
});
