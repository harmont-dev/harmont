import { type JSX, Show } from "solid-js";

export type BadgeVariant =
  | "queued"
  | "waiting"
  | "running"
  | "passed"
  | "failed"
  | "canceled"
  | "timed-out"
  | "skipped"
  | "accent"
  | "muted";

export type StatusBadgeProps = {
  text: string;
  variant: BadgeVariant;
  pulse?: boolean;
  class?: string;
};

const variantClasses: Record<BadgeVariant, { base: string; dot: string }> = {
  queued:     { base: "border-l-status-queued text-status-queued bg-status-queued/8",         dot: "bg-status-queued" },
  waiting:    { base: "border-l-status-waiting text-status-waiting bg-status-waiting/8 border-dashed", dot: "bg-status-waiting" },
  running:    { base: "border-l-status-running text-status-running bg-status-running/8",      dot: "bg-status-running" },
  passed:     { base: "border-l-status-passed text-status-passed bg-status-passed/8",         dot: "bg-status-passed" },
  failed:     { base: "border-l-status-failed text-status-failed bg-status-failed/8",         dot: "bg-status-failed" },
  canceled:   { base: "border-l-status-canceled text-status-canceled bg-status-canceled/8",   dot: "bg-status-canceled" },
  "timed-out": { base: "border-l-status-timed-out text-status-timed-out bg-status-timed-out/8", dot: "bg-status-timed-out" },
  skipped:    { base: "border-l-status-skipped text-status-skipped bg-status-skipped/8",      dot: "bg-status-skipped" },
  accent:     { base: "border-l-accent text-accent-hover bg-accent/8",                        dot: "bg-accent" },
  muted:      { base: "border-l-fg-dim text-fg-muted bg-fg-dim/8",                            dot: "bg-fg-dim" },
};

export function StatusBadge(props: StatusBadgeProps) {
  const v = () => variantClasses[props.variant];

  return (
    <span
      class={`inline-flex items-center gap-[6px] py-1 px-2 font-mono text-2xs font-medium uppercase tracking-[0.04em] leading-[1.2] border-l-2 rounded-[2px] ${v().base} ${props.class ?? ""}`.trim()}
    >
      <Show when={props.pulse}>
        <span class={`flex items-center justify-center w-[7px] h-[7px] rounded-[1px] shrink-0 animate-pulse ${v().dot}`} />
      </Show>
      {props.text}
    </span>
  );
}
