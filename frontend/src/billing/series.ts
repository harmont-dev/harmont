import type { components } from "../api/v1";

type Bucket = components["schemas"]["UsageSeriesBucket"];

export type SeriesTotals = {
  cpuSeconds: number;
  memorySeconds: number;
  diskSeconds: number;
  totalCents: number;
};

export function sumSeries(buckets: Bucket[]): SeriesTotals {
  return buckets.reduce<SeriesTotals>(
    (acc, b) => ({
      cpuSeconds: acc.cpuSeconds + b.cpu_seconds,
      memorySeconds: acc.memorySeconds + b.memory_gb_seconds,
      diskSeconds: acc.diskSeconds + b.disk_gb_seconds,
      totalCents: acc.totalCents + b.total_cents,
    }),
    { cpuSeconds: 0, memorySeconds: 0, diskSeconds: 0, totalCents: 0 },
  );
}

export function usageChartData(buckets: Bucket[]): { labels: string[]; cents: number[] } {
  return { labels: buckets.map((b) => b.date), cents: buckets.map((b) => b.total_cents) };
}
