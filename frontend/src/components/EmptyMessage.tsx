import type { JSX } from "solid-js";

export function EmptyMessage(props: { children: JSX.Element }) {
  return (
    <div class="text-fg-muted font-mono text-sm py-8 text-center">
      {props.children}
    </div>
  );
}
