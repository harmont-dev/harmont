import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { DynamicCodeBlock } from 'fumadocs-ui/components/dynamic-codeblock';
import { examplesRoot } from '@/lib/repo-root';

interface RemoteCodeProps {
  /** Path relative to the examples directory, e.g. `react/.hm/pipeline.py`. */
  src: string;
  /** Shiki language id, e.g. `python`, `rust`, `typescript`. */
  lang: string;
  /** Optional caption shown above the code block. */
  title?: string;
}

/**
 * Server component. Reads `src` from disk at build time and renders it as a
 * Fumadocs `DynamicCodeBlock` with shiki highlighting and a copy button.
 *
 * Throws if the file is missing — fail fast, so docs
 * never silently render an empty code block when an example is renamed.
 */
export async function RemoteCode({ src, lang, title }: RemoteCodeProps) {
  const absolute = path.join(examplesRoot(), src);
  let code: string;
  try {
    code = await readFile(absolute, 'utf-8');
  } catch (error) {
    throw new Error(
      `<RemoteCode src="${src}">: file not found at ${absolute}\n` +
        `  → src is relative to the examples directory (harmont-cli/examples/); ` +
        `check the file is committed and the submodule is checked out`,
      { cause: error },
    );
  }
  // Trim trailing newline that text editors add; the code block adds its own padding.
  code = code.replace(/\n+$/, '');
  return (
    <figure>
      {title ? <figcaption className="font-mono text-sm text-fd-muted-foreground px-4 py-2">{title}</figcaption> : null}
      <DynamicCodeBlock code={code} lang={lang} />
    </figure>
  );
}
