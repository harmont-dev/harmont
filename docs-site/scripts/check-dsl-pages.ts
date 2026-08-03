import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { dslSymbols } from '../lib/dsl-api';

const OUT_ROOT = 'content/docs/pipeline-sdk/reference';

const pages = new Set(dslSymbols.map((s) => s.page));
const missing = [...pages].filter((p) => !existsSync(join(OUT_ROOT, `${p}.mdx`))).sort();

if (missing.length > 0) {
  console.error(
    `error: ${missing.length} pipeline SDK reference page(s) are missing:\n` +
      missing.map((p) => `  - ${OUT_ROOT}/${p}.mdx`).join('\n') +
      `\nRun "make docs-generate" (extractor + generator).`,
  );
  process.exit(1);
}

if (!existsSync(join(OUT_ROOT, 'index.mdx'))) {
  console.error(`error: ${OUT_ROOT}/index.mdx is missing. Run "make docs-generate".`);
  process.exit(1);
}

console.log(`OK: ${pages.size} pipeline SDK reference pages present for ${dslSymbols.length} symbols.`);
