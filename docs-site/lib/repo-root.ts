import path from 'node:path';

/**
 * Absolute path to the harmont monorepo root.
 *
 * Next.js builds the docs site from `docs-site/`, so the repo root is one
 * directory up. Centralizing this lets server components reference paths
 * relative to the repo (`examples/react/.hm/pipeline.py`) instead of
 * relative to `docs-site/` (`../examples/react/.hm/pipeline.py`).
 */
export function repoRoot(): string {
  return path.resolve(process.cwd(), '..');
}

/**
 * Absolute path to the directory holding the example projects.
 *
 * The examples live in the `harmont-cli` submodule (`harmont-cli/examples/`).
 * Locally that path is resolved relative to the repo root. The docs Docker
 * build context is `docs-site/` (so the submodule isn't visible); the deploy
 * script stages the examples into the context and sets `HARMONT_EXAMPLES_DIR`
 * to where they land in the image. The `<Tree>` and `<RemoteCode>` components —
 * the only consumers — take paths relative to this directory (e.g. `react`,
 * `react/.hm/pipeline.py`), so a future move is a one-line change here.
 */
export function examplesRoot(): string {
  return process.env.HARMONT_EXAMPLES_DIR ?? path.join(repoRoot(), 'harmont-cli', 'examples');
}
