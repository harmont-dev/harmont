import { errorCatalog } from '../lib/error-catalog';
import { readdirSync } from 'node:fs';

const dir = 'content/docs/api/errors';

const codes = new Set(errorCatalog.map((e) => e.code));
const pages = new Set(
  readdirSync(dir)
    .filter((f) => f.endsWith('.mdx') && f !== 'index.mdx')
    .map((f) => f.replace(/\.mdx$/, '')),
);

const missingPages = [...codes].filter((c) => !pages.has(c)).sort();
const orphanPages = [...pages].filter((p) => !codes.has(p)).sort();

if (missingPages.length || orphanPages.length) {
  if (missingPages.length) {
    console.error(
      `error: ${missingPages.length} error code(s) have no docs page:\n` +
        missingPages.map((c) => `  - ${c} (expected ${dir}/${c}.mdx)`).join('\n') +
        `\nRun "pnpm run scaffold:errors" then fill in the prose.`,
    );
  }
  if (orphanPages.length) {
    console.error(
      `error: ${orphanPages.length} docs page(s) have no matching error code:\n` +
        orphanPages.map((p) => `  - ${dir}/${p}.mdx`).join('\n') +
        `\nEither the code was renamed/removed in the API or the page is stale.`,
    );
  }
  process.exit(1);
}

console.log(`OK: ${codes.size} error codes each have exactly one docs page.`);
