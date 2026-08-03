import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const enabled = process.env.HARMONT_SDK_INSTALL_TEST === "1";

test(
  "the published tarball installs and imports as a real consumer",
  { skip: enabled ? false : "set HARMONT_SDK_INSTALL_TEST=1 (needs network)" },
  () => {
    // 1. Build the real tarball into a temp dir.
    const work = mkdtempSync(join(tmpdir(), "harmont-sdk-install-"));
    execFileSync("npm", ["pack", "--pack-destination", work], {
      cwd: pkgDir,
      stdio: "inherit",
    });
    const tarball = readdirSync(work).find((f) => f.endsWith(".tgz"));
    assert.ok(tarball, "npm pack produced a .tgz");

    // 2. Create a throwaway consumer project and install the tarball.
    const consumer = mkdtempSync(join(tmpdir(), "harmont-sdk-consumer-"));
    writeFileSync(
      join(consumer, "package.json"),
      JSON.stringify({ name: "consumer", version: "1.0.0", type: "module" }),
    );
    execFileSync("npm", ["install", join(work, tarball)], {
      cwd: consumer,
      stdio: "inherit",
    });

    // 3. Import it exactly as a consumer would and assert the surface.
    const probe = join(consumer, "probe.mjs");
    writeFileSync(
      probe,
      [
        "import { createBuild, createClient, createConfig, client } from '@harmont/cloud';",
        "if (typeof createBuild !== 'function') throw new Error('createBuild missing');",
        "if (typeof createClient !== 'function') throw new Error('createClient missing');",
        "if (typeof createConfig !== 'function') throw new Error('createConfig missing');",
        "if (!client) throw new Error('client missing');",
        "console.log('consumer import ok');",
      ].join("\n"),
    );
    const out = execFileSync("node", [probe], { cwd: consumer, encoding: "utf8" });
    assert.match(out, /consumer import ok/);
  },
);
