import type { source } from '@/lib/source';

type Page = ReturnType<typeof source.getPages>[number];

/**
 * Render one docs page as standalone Markdown for AI agents: an H1 with the
 * page title and its canonical URL, then the page's processed Markdown body
 * (cleaned by `toAgentMarkdown`). The URL line lets an agent cite or re-fetch
 * the source even when this text is read out of context (e.g. inside
 * llms-full.txt).
 */
export async function getLLMText(page: Page): Promise<string> {
  const processed = await page.data.getText('processed');
  return `# ${page.data.title} (${page.url})\n\n${toAgentMarkdown(processed)}`;
}

/**
 * Fumadocs' processed-Markdown serializer emits two artifacts that are hostile
 * to an agent (and to any non-MDX Markdown reader):
 *
 *  1. It escapes the leading `*` of a bold run that follows certain characters
 *     (e.g. an emoji) as the HTML entity `&#x2A;`, so `✅ **Do**` serializes as
 *     `✅ &#x2A;*Do**`. We restore those asterisks.
 *  2. It leaves MDX tab components (`<SdkTabs>`/`<Tabs>` + `<Tab value="…">`) as
 *     literal JSX and indents their bodies by the nesting depth, so the code
 *     fences inside come out as indented blocks wrapped in component tags. We
 *     unwrap each tab into a bold language label followed by its de-indented
 *     body.
 *
 * Components we don't special-case (e.g. APIPage on generated reference pages)
 * still serialize as literal JSX — acceptable, since the prose pages agents
 * most need use tabs, which this handles.
 */
export function toAgentMarkdown(md: string): string {
  const deEntitied = md.replaceAll('&#x2A;', '*');

  // Diagram components (<PipelineDag …/>) render to nothing in Markdown, but
  // their `caption` is a complete prose description of what the diagram shows —
  // emit that instead of the JSX blob.
  const deDiagrammed = deEntitied.replace(
    /<PipelineDag\b[\s\S]*?\/>/g,
    (block) => block.match(/caption="([^"]*)"/)?.[1] ?? '',
  );

  const out: string[] = [];
  let stripIndent: number | null = null; // leading-space count to strip inside a <Tab>

  for (const line of deDiagrammed.split('\n')) {
    const trimmed = line.trim();

    // Drop the tab-group wrappers entirely.
    if (/^<\/?(SdkTabs|Tabs)(\s[^>]*)?>$/.test(trimmed)) continue;

    // Opening tab → emit a bold language label and remember its body indent.
    const open = trimmed.match(/^<Tab\s+value="([^"]+)"\s*>$/);
    if (open) {
      if (out.at(-1) !== '') out.push('');
      out.push(`**${open[1]}**`, '');
      stripIndent = line.indexOf('<') + 2;
      continue;
    }

    if (trimmed === '</Tab>') {
      stripIndent = null;
      continue;
    }

    // Inside a tab, strip exactly the wrapper indent so the body's own
    // indentation (e.g. Python block structure) is preserved.
    if (stripIndent !== null && line.startsWith(' '.repeat(stripIndent))) {
      out.push(line.slice(stripIndent));
    } else {
      out.push(line);
    }
  }

  // Collapse the blank-line runs the unwrapping can introduce.
  return out.join('\n').replace(/\n{3,}/g, '\n\n');
}
