import { onMount } from "solid-js";
import {
  Chart as ChartJS,
  BarElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  type ChartData,
  type ChartOptions,
} from "chart.js";
import { Bar } from "solid-chartjs";
import { format, parseISO } from "date-fns";
import { renderCents } from "../billing/format";

export type UsageChartProps = { points: { date: string; cents: number }[] };

function shortLabel(date: string): string {
  try {
    return format(parseISO(date), "MMM d");
  } catch {
    return date;
  }
}

// Chart.js renders to canvas and needs concrete color strings, so we resolve
// the design tokens from index.css to their computed values once at render.
function tokenColor(name: string, fallback: string): string {
  if (typeof document === "undefined") return fallback;
  const v = getComputedStyle(document.documentElement)
    .getPropertyValue(name)
    .trim();
  return v || fallback;
}

export function UsageChart(props: UsageChartProps) {
  onMount(() => {
    ChartJS.register(BarElement, CategoryScale, LinearScale, Tooltip);
  });

  const c = {
    accent: tokenColor("--color-accent", "#2563eb"),
    accentHover: tokenColor("--color-accent-hover", "#3b82f6"),
    bgRaise: tokenColor("--color-bg-raise", "#151515"),
    border: tokenColor("--color-border", "#2a2a2a"),
    borderSubtle: tokenColor("--color-border-subtle", "#1f1f1f"),
    fgMuted: tokenColor("--color-fg-muted", "#737373"),
    fg: tokenColor("--color-fg", "#e5e5e5"),
    fgSecondary: tokenColor("--color-fg-secondary", "#a3a3a3"),
  };

  const data = (): ChartData<"bar"> => ({
    labels: props.points.map((p) => shortLabel(p.date)),
    datasets: [
      {
        data: props.points.map((p) => p.cents),
        backgroundColor: c.accent,
        hoverBackgroundColor: c.accentHover,
        borderRadius: 1,
        maxBarThickness: 18,
      },
    ],
  });

  const options: ChartOptions<"bar"> = {
    responsive: true,
    maintainAspectRatio: false,
    animation: { duration: 200 },
    plugins: {
      legend: { display: false },
      tooltip: {
        backgroundColor: c.bgRaise,
        borderColor: c.border,
        borderWidth: 1,
        cornerRadius: 2,
        padding: 10,
        displayColors: false,
        titleColor: c.fg,
        bodyColor: c.fgSecondary,
        titleFont: { family: "JetBrains Mono", size: 12 },
        bodyFont: { family: "JetBrains Mono", size: 12 },
        callbacks: { label: (ctx) => renderCents(Number(ctx.parsed.y)) },
      },
    },
    scales: {
      x: {
        grid: { display: false },
        border: { color: c.border },
        ticks: {
          color: c.fgMuted,
          font: { family: "JetBrains Mono", size: 11 },
          maxRotation: 0,
          autoSkip: true,
          maxTicksLimit: 8,
        },
      },
      y: {
        beginAtZero: true,
        grid: { color: c.borderSubtle },
        border: { display: false },
        ticks: {
          color: c.fgMuted,
          font: { family: "JetBrains Mono", size: 11 },
          callback: (v) => renderCents(Number(v)),
        },
      },
    },
  };

  return (
    <div class="relative h-[200px] w-full">
      <Bar data={data()} options={options} />
    </div>
  );
}
