import type { JSX } from "solid-js";

/** Vertical list of rows separated by hairline dividers (Settings sections). */
export function PanelList(props: { children: JSX.Element; class?: string }) {
  return (
    <div class={`flex flex-col divide-y divide-border-subtle ${props.class ?? ""}`.trim()}>
      {props.children}
    </div>
  );
}

/**
 * A single row inside a `PanelList`. Defaults to the action-row layout
 * (icon/name on the left, action on the right). The first/last rows shed their
 * outer vertical padding so the list sits flush in the panel body.
 */
export function PanelRow(props: { children: JSX.Element; class?: string }) {
  return (
    <div class={`flex items-center gap-3 py-3 first:pt-0 last:pb-0 ${props.class ?? ""}`.trim()}>
      {props.children}
    </div>
  );
}
