/* @refresh reload */
import { Show, createSignal, createMemo } from "solid-js";
import { SectionHeading } from "../components/SectionHeading";
import { QueryGuard } from "../components/QueryGuard";
import { TimeAgo } from "../components/TimeAgo";
import { Table, type Column } from "../components/Table";
import { UsageChart } from "../components/UsageChart";
import { PeriodSelector } from "../components/PeriodSelector";
import { useOrgSlug } from "../auth/context";
import { useBalance, useTransactions, useUsageSeries, useUsageBreakdown } from "../billing/queries";
import { UsageBreakdown } from "../billing/UsageBreakdown";
import { renderCents, sourceLabel } from "../billing/format";
import { sumSeries, usageChartData } from "../billing/series";
import { UsageHeader } from "../billing/UsageHeader";
import { SpendSummary } from "../billing/SpendSummary";
import { ResourceBreakdown } from "../billing/ResourceBreakdown";
import type { components } from "../api/v1";

type TransactionResponse = components["schemas"]["Transaction"];

const transactionColumns: Column<TransactionResponse>[] = [
  {
    key: "when",
    label: "When",
    render: (t) => <TimeAgo date={t.created_at} />,
  },
  {
    key: "source",
    label: "Source",
    render: (t) => <span class="text-fg">{sourceLabel(t.source)}</span>,
  },
  {
    key: "description",
    label: "Description",
    render: (t) => <span class="text-fg-muted">{t.description}</span>,
  },
  {
    key: "amount",
    label: "Amount",
    align: "right",
    render: (t) => (
      <span class={`font-mono text-xs ${t.amount_cents < 0 ? "text-fg-muted" : "text-ok"}`}>
        {renderCents(t.amount_cents)}
      </span>
    ),
  },
];

export function BillingPage() {
  const orgSlug = useOrgSlug();
  const [days, setDays] = createSignal(30);

  const balance = useBalance(orgSlug);
  const series = useUsageSeries(orgSlug, days);
  const transactions = useTransactions(orgSlug);
  const breakdown = useUsageBreakdown(orgSlug, days);

  // VM-lease debits are shown, with full context, in the VM usage breakdown
  // below; keep the Transactions ledger to money movements (top-ups, credits,
  // refunds) so it isn't drowned in per-lease rows.
  const ledgerRows = () =>
    (transactions.data?.data ?? []).filter((t) => t.source !== "vm_lease_debit");

  const buckets = () => series.data?.data ?? [];
  const totals = createMemo(() => sumSeries(buckets()));
  const chartPoints = createMemo(() => {
    const { labels, cents } = usageChartData(buckets());
    return labels.map((date, i) => ({ date, cents: cents[i] ?? 0 }));
  });
  const avgPerDay = () => Math.round(totals().totalCents / Math.max(1, days()));

  return (
    <div class="max-w-[960px] mx-auto">
      <UsageHeader balanceCents={balance.data?.balance_cents ?? 0} orgSlug={orgSlug} />

      <section class="mb-8">
        <SectionHeading action={<PeriodSelector value={days()} onChange={setDays} />}>
          Breakdown
        </SectionHeading>
        <QueryGuard query={series} loadingRows={1} loadingHeight={320}>
          <div class="space-y-6">
            <SpendSummary spentCents={totals().totalCents} avgPerDayCents={avgPerDay()} />
            <UsageChart points={chartPoints()} />
            <ResourceBreakdown totals={totals()} />
          </div>
        </QueryGuard>
      </section>

      <section class="mb-8">
        <SectionHeading>VM usage</SectionHeading>
        <QueryGuard query={breakdown} loadingRows={4}>
          <Show
            when={(breakdown.data?.data ?? []).length > 0}
            fallback={
              <div class="text-fg-muted font-mono text-sm py-4">
                No VM usage in this period.
              </div>
            }
          >
            <UsageBreakdown builds={breakdown.data?.data ?? []} />
          </Show>
        </QueryGuard>
      </section>

      <section>
        <SectionHeading>Transactions</SectionHeading>
        <QueryGuard query={transactions} loadingRows={4}>
          <Show
            when={ledgerRows().length > 0}
            fallback={
              <div class="text-fg-muted font-mono text-sm py-4">
                No top-ups or credits yet.
              </div>
            }
          >
            <Table columns={transactionColumns} rows={ledgerRows()} />
          </Show>
        </QueryGuard>
      </section>
    </div>
  );
}
