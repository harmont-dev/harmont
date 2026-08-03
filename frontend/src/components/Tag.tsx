import type { JSX } from "solid-js";

export type TagVariant = "default" | "ok" | "muted" | "warn" | "err" | "accent";

const variantClasses: Record<TagVariant, string> = {
  default: "text-fg bg-fg-dim/10",
  ok: "text-ok bg-ok/10",
  muted: "text-fg-muted bg-fg-dim/10",
  warn: "text-warn bg-warn/10",
  err: "text-err bg-err/10",
  accent: "text-accent bg-accent/10",
};

export function Tag(props: {
  variant?: TagVariant;
  children: JSX.Element;
  class?: string;
}) {
  const v = () => props.variant ?? "default";
  return (
    <span
      class={`inline-flex items-center font-mono text-2xs uppercase tracking-[0.04em] py-[2px] px-[6px] rounded-[2px] ${variantClasses[v()]} ${props.class ?? ""}`.trim()}
    >
      {props.children}
    </span>
  );
}
