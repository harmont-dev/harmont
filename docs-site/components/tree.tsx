import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { File, Files, Folder } from 'fumadocs-ui/components/files';
import { examplesRoot } from '@/lib/repo-root';

interface TreeProps {
  /** Path relative to the examples directory, e.g. `react`. */
  path: string;
  /** Max nesting depth to recurse into. Default 4. */
  maxDepth?: number;
}

// Directories ignored when rendering example trees — generated build state
// shouldn't appear in the source tree shown to readers. `bin/` is intentionally
// NOT here: OCaml's dune layout commits source under `bin/`. Build artifacts
// like `bin/Debug` and `bin/Release` are already gitignored at the repo level,
// so they don't appear in the committed tree.
const IGNORE = new Set([
  'node_modules',
  '.next',
  'dist',
  'build',
  'target',
  '__pycache__',
  '.pytest_cache',
  '.ruff_cache',
  '.mypy_cache',
  '.venv',
  'vendor',
  '_build',
  'zig-out',
  'zig-cache',
  '.zig-cache',
  '.gradle',
  'obj',
  'dist-newstyle',
  '.local',
]);

interface Entry {
  name: string;
  absolute: string;
  isDir: boolean;
}

async function readEntries(dir: string): Promise<Entry[]> {
  // withFileTypes avoids a per-entry stat syscall and the TOCTOU window
  // between readdir and stat.
  const dirents = await readdir(dir, { withFileTypes: true });
  return dirents
    .filter((e) => !IGNORE.has(e.name))
    .map((e) => ({
      name: e.name,
      absolute: path.join(dir, e.name),
      isDir: e.isDirectory(),
    }))
    .sort((a, b) => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
}

async function renderEntries(dir: string, depth: number, maxDepth: number): Promise<React.ReactNode[]> {
  if (depth > maxDepth) return [];
  const entries = await readEntries(dir);
  return Promise.all(
    entries.map(async (entry) => {
      if (entry.isDir) {
        const children = await renderEntries(entry.absolute, depth + 1, maxDepth);
        return (
          <Folder key={entry.absolute} name={entry.name}>
            {children}
          </Folder>
        );
      }
      return <File key={entry.absolute} name={entry.name} />;
    }),
  );
}

/**
 * Server component. Renders the directory tree rooted at `path` (repo-relative)
 * using Fumadocs' `Files` / `Folder` / `File` primitives. Ignores common build
 * output directories so readers see only committed source.
 */
export async function Tree({ path: rel, maxDepth = 4 }: TreeProps) {
  const absolute = path.join(examplesRoot(), rel);
  let children: React.ReactNode[];
  try {
    children = await renderEntries(absolute, 1, maxDepth);
  } catch (error) {
    throw new Error(
      `<Tree path="${rel}">: directory not found at ${absolute}\n` +
        `  → path is relative to the examples directory (harmont-cli/examples/); ` +
        `check the directory exists and the submodule is checked out`,
      { cause: error },
    );
  }
  return <Files>{children}</Files>;
}
