import { For } from "solid-js";
import { renderHours } from "./format";
import type { SeriesTotals } from "./series";

const SECONDS_PER_HOUR = 3600;

export function ResourceBreakdown(props: { totals: SeriesTotals }) {
  const rows = () => [
    { label: "CPU", value: `${renderHours(props.totals.cpuSeconds / SECONDS_PER_HOUR)} h` },
    { label: "Memory", value: `${renderHours(props.totals.memorySeconds / SECONDS_PER_HOUR)} GB·h` },
    { label: "Storage", value: `${renderHours(props.totals.diskSeconds / SECONDS_PER_HOUR)} GB·h` },
  ];

  return (
    <div>
      <div class="font-mono text-2xs uppercase tracking-[0.06em] text-fg-muted mb-2">Resources</div>
      <For each={rows()}>
        {(row) => (
          <div class="flex items-baseline justify-between border-b border-border-subtle last:border-b-0 py-2">
            <span class="text-fg-secondary text-sm">{row.label}</span>
            <span class="font-mono text-sm text-fg">{row.value}</span>
          </div>
        )}
      </For>
    </div>
  );
}
