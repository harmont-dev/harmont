import { defineConfig, defineDocs } from 'fumadocs-mdx/config';

export const docs = defineDocs({
  dir: 'content/docs',
  // Exclude the hand-authored intro snippets under api/_intros/. They have
  // no frontmatter on purpose — the docs-generate step splices their bodies
  // into the matching api/reference/<tag>.mdx files.
  docs: {
    files: ['**/*.mdx', '!api/_intros/**'],
    // Emit serialized Markdown alongside the compiled MDX so route handlers
    // can serve agent-facing `.md` and `/llms-full.txt` via getText('processed').
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    files: ['**/*.json', '!api/_intros/**'],
  },
});

export default defineConfig();
