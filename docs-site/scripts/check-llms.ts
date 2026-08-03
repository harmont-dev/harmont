import { existsSync, readFileSync } from 'node:fs';

const required = [
  'lib/get-llm-text.ts',
  'middleware.ts',
  'app/llms.txt/route.ts',
  'app/llms-full.txt/route.ts',
  'app/llms.mdx/[[...slug]]/route.ts',
  'app/robots.ts',
  'app/sitemap.ts',
  'components/markdown-actions.tsx',
  'content/docs/agents.mdx',
  'content/docs/pipeline-sdk/patterns.mdx',
];

const missing = required.filter((p) => !existsSync(p));
if (missing.length > 0) {
  console.error(
    `error: ${missing.length} agent-docs file(s) missing:\n` +
      missing.map((p) => `  - ${p}`).join('\n'),
  );
  process.exit(1);
}

// processed-markdown must stay enabled or every .md route serves empty bodies.
if (!/includeProcessedMarkdown:\s*true/.test(readFileSync('source.config.ts', 'utf8'))) {
  console.error('error: source.config.ts must set includeProcessedMarkdown: true');
  process.exit(1);
}

// the /:path*.md rewrite must stay wired, or every per-page .md URL 404s while
// the build still passes. Guard the rewrite target in next.config.mjs.
if (!/\/llms\.mdx\/:path\*/.test(readFileSync('next.config.mjs', 'utf8'))) {
  console.error('error: next.config.mjs must rewrite /:path*.md to /llms.mdx/:path*');
  process.exit(1);
}

// patterns page must keep the toolchain-over-hm.sh nudge.
const patterns = readFileSync('content/docs/pipeline-sdk/patterns.mdx', 'utf8');
if (!/toolchain/.test(patterns) || !/hm\.sh/.test(patterns)) {
  console.error('error: patterns.mdx must contrast toolchains with hm.sh');
  process.exit(1);
}

// nav wiring. patterns is part of the human learning path, so it must stay in
// the sidebar. agents.mdx is intentionally NOT in the sidebar — it's agent-
// facing infra reached via /llms.txt and /agents.md, so we only guard that the
// page exists (see `required` above), not that it's in the nav.
const sdkMeta = readFileSync('content/docs/pipeline-sdk/meta.json', 'utf8');
if (!/"patterns"/.test(sdkMeta)) {
  console.error('error: pipeline-sdk/meta.json must list "patterns"');
  process.exit(1);
}

console.log('check-llms: OK');
