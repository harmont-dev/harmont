import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");

// Build the SDK, then ask npm what the tarball WOULD contain. We pass
// --ignore-scripts so the `prepack` hook (codegen + tsup) does not run during
// the pack and pollute the --json stdout we parse; we run codegen + build
// explicitly first so dist/ exists. All three steps are offline. Memoized so
// the two tests below share one build instead of paying for it twice.
let cached: string[] | undefined;
function packedFiles(): string[] {
  if (cached) return cached;
  execFileSync("npm", ["run", "codegen"], { cwd: pkgDir, stdio: "ignore" });
  execFileSync("npm", ["run", "build"], { cwd: pkgDir, stdio: "ignore" });
  const out = execFileSync(
    "npm",
    ["pack", "--dry-run", "--json", "--ignore-scripts"],
    { cwd: pkgDir, encoding: "utf8" },
  );
  const report = JSON.parse(out) as Array<{ files: Array<{ path: string }> }>;
  const entry = report[0];
  assert.ok(entry, "npm pack --json returned a report entry");
  cached = entry.files.map((f) => f.path);
  return cached;
}

test("tarball ships the built dist and package metadata", () => {
  const files = packedFiles();
  for (const required of [
    "dist/index.js",
    "dist/index.cjs",
    "dist/index.d.ts",
    "dist/index.d.cts",
    "package.json",
    "README.md",
    "LICENSE",
  ]) {
    assert.ok(files.includes(required), `expected ${required} in tarball`);
  }
});

test("tarball does NOT ship source, tests, or configs", () => {
  const files = packedFiles();
  const forbidden = (p: string) =>
    p.startsWith("src/") ||
    p.startsWith("e2e/") ||
    p.startsWith("node_modules/") ||
    p.endsWith("tsconfig.json") ||
    p.endsWith("openapi-ts.config.ts") ||
    p.endsWith("tsup.config.ts");
  const leaked = files.filter(forbidden);
  assert.deepEqual(leaked, [], `leaked files: ${leaked.join(", ")}`);
});
