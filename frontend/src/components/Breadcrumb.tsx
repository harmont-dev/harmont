import { type JSX, For } from "solid-js";
import { A } from "@solidjs/router";

type Crumb = { label: string | JSX.Element; href?: string };

export function Breadcrumb(props: { crumbs: Crumb[] }) {
  return (
    <nav class="flex items-center gap-1.5 font-mono text-xs text-fg-muted mb-4">
      <For each={props.crumbs}>
        {(crumb, i) => (
          <>
            {i() > 0 && <span class="text-fg-dim">/</span>}
            {crumb.href ? (
              <A href={crumb.href} class="text-fg-muted hover:text-fg no-underline">
                {crumb.label}
              </A>
            ) : (
              <span class="text-fg">{crumb.label}</span>
            )}
          </>
        )}
      </For>
    </nav>
  );
}
