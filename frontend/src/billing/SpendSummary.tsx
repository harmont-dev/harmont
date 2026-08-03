import { renderCents } from "./format";

export function SpendSummary(props: { spentCents: number; avgPerDayCents: number }) {
  return (
    <div class="flex gap-12">
      <div>
        <div class="font-mono text-2xs uppercase tracking-[0.06em] text-fg-muted">Spent</div>
        <div class="font-mono text-2xl font-semibold text-fg">{renderCents(props.spentCents)}</div>
      </div>
      <div>
        <div class="font-mono text-2xs uppercase tracking-[0.06em] text-fg-muted">Avg / day</div>
        <div class="font-mono text-2xl font-semibold text-fg">{renderCents(props.avgPerDayCents)}</div>
      </div>
    </div>
  );
}
