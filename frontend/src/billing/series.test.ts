import { describe, expect, it } from "vitest";
import { sumSeries, usageChartData } from "./series";
import type { components } from "../api/v1";

type Bucket = components["schemas"]["UsageSeriesBucket"];

const buckets: Bucket[] = [
  { date: "2026-01-01", cpu_seconds: 1200, memory_gb_seconds: 2400, disk_gb_seconds: 200, total_cents: 10 },
  { date: "2026-01-02", cpu_seconds: 0, memory_gb_seconds: 0, disk_gb_seconds: 0, total_cents: 0 },
  { date: "2026-01-03", cpu_seconds: 600, memory_gb_seconds: 600, disk_gb_seconds: 60, total_cents: 5 },
];

describe("sumSeries", () => {
  it("sums each field across buckets", () => {
    expect(sumSeries(buckets)).toEqual({ cpuSeconds: 1800, memorySeconds: 3000, diskSeconds: 260, totalCents: 15 });
  });
  it("returns zeros for an empty series", () => {
    expect(sumSeries([])).toEqual({ cpuSeconds: 0, memorySeconds: 0, diskSeconds: 0, totalCents: 0 });
  });
});

describe("usageChartData", () => {
  it("maps buckets to labels + cents arrays in order", () => {
    const { labels, cents } = usageChartData(buckets);
    expect(labels).toEqual(["2026-01-01", "2026-01-02", "2026-01-03"]);
    expect(cents).toEqual([10, 0, 5]);
  });
});
