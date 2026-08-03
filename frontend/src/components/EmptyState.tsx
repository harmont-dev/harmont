import type { JSX } from "solid-js";

/** Dashed-border placeholder for an empty list section. */
export function EmptyState(props: { children: JSX.Element }) {
  return (
    <div class="p-3 border border-border border-dashed rounded-[2px] font-mono text-xs text-fg-dim">
      {props.children}
    </div>
  );
}
