import { For } from "solid-js";

export type PeriodSelectorProps = { value: number; onChange: (days: number) => void; options?: number[] };
const DEFAULTS = [7, 30, 90];

export function PeriodSelector(props: PeriodSelectorProps) {
  const opts = () => props.options ?? DEFAULTS;
  return (
    <div
      role="radiogroup"
      aria-label="Time period"
      class="inline-flex border border-border rounded-[2px] overflow-hidden"
    >
      <For each={opts()}>
        {(d) => (
          <button
            type="button"
            role="radio"
            aria-checked={props.value === d}
            class={`px-2.5 py-1 font-mono text-2xs font-medium uppercase tracking-[0.04em] cursor-pointer border-r border-border last:border-r-0 ${
              props.value === d
                ? "text-fg bg-bg-hover"
                : "text-fg-muted bg-transparent hover:text-fg hover:bg-bg-hover"
            }`}
            onClick={() => props.onChange(d)}
          >
            {d}d
          </button>
        )}
      </For>
    </div>
  );
}
