import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The generated surface is a gitignored build artifact. If it has not been
// generated yet (`npm run codegen`), skip rather than throw on the unresolved
// import — so a bare `npm test` stays green before codegen has run.
const generated = fileURLToPath(
  new URL("../src/generated/index.ts", import.meta.url),
);

test(
  "public entrypoint re-exports the SDK surface and client helpers",
  { skip: existsSync(generated) ? false : "run `npm run codegen` first" },
  async () => {
    const sdk = await import("../src/index.ts");
    // Operation functions (one per operationId)
    assert.equal(typeof sdk.createBuild, "function");
    assert.equal(typeof sdk.getBuild, "function");
    assert.equal(typeof sdk.createPipeline, "function");
    assert.equal(typeof sdk.listOrganizations, "function");
    // Client construction helpers (re-exported from the generated client)
    assert.equal(typeof sdk.createClient, "function");
    assert.equal(typeof sdk.createConfig, "function");
    // The default client instance
    assert.ok(sdk.client, "default client is exported");
  },
);
