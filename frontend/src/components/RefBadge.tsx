import type { JSX } from "solid-js";

export function RefBadge(props: { children: JSX.Element; class?: string }) {
  return (
    <span
      class={`inline-flex items-center font-mono text-xs text-fg py-[2px] px-[7px] border border-border-active bg-bg-inset rounded-[2px] ${props.class ?? ""}`.trim()}
    >
      {props.children}
    </span>
  );
}
