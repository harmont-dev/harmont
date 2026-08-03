import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { extractSdkApi } from '../lib/sdk-api-core';

// openapi.json is copied into docs-site/ by `make docs-generate` from the
// PUBLIC spec, so this naturally covers only the public operations.
const SPEC = 'openapi.json';
const OUT = 'sdk-api.json';

// Optional integrity check: when the SDK package's generated client is present,
// confirm every derived function name is actually exported by the SDK, so the
// docs never claim a function the package doesn't ship.
const SDK_GEN = join('..', 'oss', 'harmont-cloud-sdk', 'src', 'generated', 'sdk.gen.ts');

function main(): void {
  if (!existsSync(SPEC)) {
    console.error(`error: ${SPEC} not found. Run "make docs-generate" first (it copies the public spec).`);
    process.exit(1);
  }
  const spec = JSON.parse(readFileSync(SPEC, 'utf8'));
  if (!spec || typeof spec.paths !== 'object') {
    console.error(`error: ${SPEC} has no "paths" object — is it a valid OpenAPI document? Re-run "make docs-generate".`);
    process.exit(1);
  }
  const api = extractSdkApi(spec);

  if (existsSync(SDK_GEN)) {
    const gen = readFileSync(SDK_GEN, 'utf8');
    const exported = new Set([...gen.matchAll(/export const ([a-zA-Z0-9_]+) =/g)].map((m) => m[1]));
    const missing = api.functions.map((f) => f.name).filter((n) => !exported.has(n));
    if (missing.length > 0) {
      console.error(
        `error: ${missing.length} public operation(s) are not exported by @harmont/cloud ` +
          `(hey-api naming drift?):\n  ${missing.join('\n  ')}`,
      );
      process.exit(1);
    }
  } else {
    console.warn(`warn: ${SDK_GEN} absent — skipping SDK export cross-check.`);
  }

  writeFileSync(OUT, JSON.stringify(api, null, 2) + '\n', 'utf8');
  console.log(`extract-sdk-api: wrote ${api.functions.length} functions to ${OUT}`);
}

main();
