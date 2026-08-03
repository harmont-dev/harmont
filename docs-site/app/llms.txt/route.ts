import { llms } from 'fumadocs-core/source/llms';
import { source } from '@/lib/source';

// Static at build time; the docs change only on deploy.
export const revalidate = false;

const PREAMBLE = `# Harmont

> Harmont is a headless CI platform. Developers push local, uncommitted code
> straight into CI pipelines with \`hm run\` — no commit or remote push first.
> Pipelines are written as Python or TypeScript programs using the high-level
> Pipeline SDK.

For an orientation written for AI agents — including how to fetch any page as
Markdown — read /agents. For the canonical do/don't patterns when writing
pipelines, read /pipeline-sdk/patterns.
`;

export function GET(): Response {
  // index() prefixes its own H1 (and, if the root meta has a description, a
  // following blockquote) from the page-tree root; drop both so our curated
  // PREAMBLE owns the single required H1 and summary.
  const body = llms(source)
    .index()
    .replace(/^#\s.*\n+/, '')
    .replace(/^(>.*\n)+\n*/, '');
  return new Response(`${PREAMBLE}\n${body}`, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
