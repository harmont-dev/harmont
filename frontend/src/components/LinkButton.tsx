import type { JSX } from "solid-js";

type Size = "sm" | "md";

const sizeClasses: Record<Size, string> = {
  sm: "px-[9px] py-1 text-2xs",
  md: "px-3 py-[7px] text-xs",
};

export function LinkButton(props: {
  href: string;
  target?: string;
  size?: Size;
  children: JSX.Element;
  class?: string;
}) {
  return (
    <a
      href={props.href}
      target={props.target}
      rel={props.target === "_blank" ? "noopener" : undefined}
      class={`inline-flex items-center justify-center gap-1 whitespace-nowrap font-mono font-medium uppercase tracking-[0.04em] leading-none text-fg-muted hover:text-fg no-underline border border-border rounded-[2px] hover:bg-bg-hover cursor-pointer transition-fast ${sizeClasses[props.size ?? "md"]} ${props.class ?? ""}`.trim()}
    >
      {props.children}
    </a>
  );
}
