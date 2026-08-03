import type { components } from "../api/v1";

type EntrySource = NonNullable<components["schemas"]["Transaction"]["source"]>;

export function renderCents(n: number): string {
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  const dollars = Math.floor(abs / 100);
  const cents = abs % 100;
  return `${sign}$${dollars}.${cents < 10 ? "0" : ""}${cents}`;
}

export function renderHours(x: number): string {
  const scaled = Math.round(x * 100);
  const sign = scaled < 0 ? "-" : "";
  const abs = Math.abs(scaled);
  const whole = Math.floor(abs / 100);
  const frac = abs % 100;
  return `${sign}${whole}.${frac < 10 ? "0" : ""}${frac}`;
}

const SOURCE_LABELS: Record<EntrySource, string> = {
  stripe_topup: "Top-up (Stripe)",
  coupon_redemption: "Coupon",
  admin_grant: "Free credit",
  vm_lease_debit: "VM usage",
  refund: "Refund",
};

export function sourceLabel(source: EntrySource): string {
  return SOURCE_LABELS[source];
}

export function renderDuration(seconds: number | null | undefined): string {
  if (seconds == null) return "—";
  if (seconds === 0) return "0s";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  const parts: string[] = [];
  if (h > 0) parts.push(`${h}h`);
  if (m > 0) parts.push(`${m}m`);
  if (s > 0) parts.push(`${s}s`);
  return parts.join(" ");
}
