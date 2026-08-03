import { type JSX, Show } from "solid-js";

export type SeparatorProps = {
  label?: JSX.Element;
  class?: string;
};

export function Separator(props: SeparatorProps) {
  return (
    <div class={`flex items-center gap-3 ${props.class ?? ""}`}>
      <div class="h-px flex-1 bg-border" />
      <Show when={props.label}>
        <span class="font-mono text-2xs text-fg-dim uppercase tracking-widest">{props.label}</span>
        <div class="h-px flex-1 bg-border" />
      </Show>
    </div>
  );
}
