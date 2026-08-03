import { renderCents } from "./format";
import { TopUp } from "./TopUp";

export function UsageHeader(props: {
  balanceCents: number;
  orgSlug: () => string | undefined;
}) {
  return (
    <div class="border-b border-border-subtle pb-6 mb-6 flex items-end justify-between gap-8">
      <div>
        <h1 class="text-xl font-semibold text-fg mb-3">Usage</h1>
        <div class="font-mono text-4xl font-semibold text-fg leading-none">
          {renderCents(props.balanceCents)}
        </div>
        <div class="font-mono text-2xs uppercase tracking-[0.06em] text-fg-muted mt-2">
          available credit
        </div>
      </div>
      <TopUp orgSlug={props.orgSlug} />
    </div>
  );
}
