import { generateFiles } from 'fumadocs-openapi';
import { openapi } from '../lib/openapi';
import { readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const OUTPUT_DIR = './content/docs/api/reference';

// Wipe the output dir before regenerating. fumadocs' generateFiles only
// *writes* pages for the current spec — it never deletes ones that no longer
// correspond to a tag/operation. Combined with the Docker build's `COPY . .`
// (which drags any locally-generated pages into the image), a stale page that
// references a since-removed endpoint survives and crashes `next build` at
// prerender. Starting from an empty dir makes the reference deterministic.
await rm(OUTPUT_DIR, { recursive: true, force: true });

void generateFiles({
  input: openapi,
  output: OUTPUT_DIR,
  per: 'tag',
  meta: true,
  index: {
    // fumadocs passes each card's `entry.path` relative to `output` (a bare
    // `<tag>.mdx`), so contentDir must be '.' — the path is already relative to
    // the reference dir. Using the full './content/docs/api/reference' here made
    // path.relative() emit four '../' segments, so every card link resolved to
    // '/<tag>' instead of '/api/reference/<tag>'.
    url: { baseUrl: '/api/reference', contentDir: '.' },
    items: [
      {
        path: 'index.mdx',
        title: 'Reference',
        description: 'Every endpoint, grouped by tag.',
      },
    ],
  },
  includeDescription: true,
  addGeneratedComment: true,
  // Prepend the matching _intros/<tag>.mdx body to each generated tag page,
  // after the frontmatter. Skips files whose name doesn't match an intro file.
  beforeWrite: async function (files) {
    for (const file of files) {
      const base = file.path.replace(/^.*\//, '').replace(/\.mdx$/, '');
      const intro = join('content/docs/api/_intros', `${base}.mdx`);
      if (!existsSync(intro)) continue;
      const introBody = await readFile(intro, 'utf8');
      // Strip frontmatter from the intro body (keep prose only).
      const proseOnly = introBody.replace(/^---[\s\S]*?---\s*/, '');
      // Splice prose between the existing frontmatter and the operations list.
      file.content = file.content.replace(
        /^(---[\s\S]*?---\s*)/,
        `$1${proseOnly}\n`,
      );
    }
  },
});
