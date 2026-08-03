import type { JSX } from "solid-js";

export function SectionHeading(props: { children: JSX.Element; action?: JSX.Element }) {
  return (
    <div class="flex items-center justify-between mb-3">
      <h2 class="font-mono text-xs font-semibold text-fg uppercase tracking-[0.06em]">
        {props.children}
      </h2>
      {props.action}
    </div>
  );
}
