import type { JSX } from "solid-js";

/**
 * A label/value row for a definition list (`<dl>`) — muted label on the left,
 * value on the right. Use inside a `<dl class="flex flex-col ...">`.
 */
export function DefRow(props: { label: string; children: JSX.Element }) {
  return (
    <div class="flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0">
      <dt class="text-sm text-fg-muted shrink-0">{props.label}</dt>
      <dd class="min-w-0 truncate text-sm text-fg">{props.children}</dd>
    </div>
  );
}
