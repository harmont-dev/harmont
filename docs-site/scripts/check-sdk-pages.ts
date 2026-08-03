import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { sdkFunctions } from '../lib/sdk-api';

const OUT_ROOT = 'content/docs/sdk/reference';

const tags = new Set(sdkFunctions.map((f) => f.tag));
const missing = [...tags].filter((t) => !existsSync(join(OUT_ROOT, `${t}.mdx`))).sort();

if (missing.length > 0) {
  console.error(
    `error: ${missing.length} SDK reference page(s) are missing:\n` +
      missing.map((t) => `  - ${OUT_ROOT}/${t}.mdx`).join('\n') +
      `\nRun "make docs-generate".`,
  );
  process.exit(1);
}

if (!existsSync(join(OUT_ROOT, 'index.mdx'))) {
  console.error(`error: ${OUT_ROOT}/index.mdx is missing. Run "make docs-generate".`);
  process.exit(1);
}

console.log(`OK: ${tags.size} SDK reference pages present for ${sdkFunctions.length} functions.`);
