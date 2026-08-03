import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { createApiClient } from "../api/client";

export const BILLING_KEYS = {
  balance: (orgSlug: string) => ["billing", orgSlug, "balance"] as const,
  transactions: (orgSlug: string) =>
    ["billing", orgSlug, "transactions"] as const,
  usageSeries: (orgSlug: string, days: number) =>
    ["billing", orgSlug, "usage-series", days] as const,
  usageBreakdown: (orgSlug: string, days: number) =>
    ["billing", orgSlug, "usage-breakdown", days] as const,
};

export function useBalance(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...BILLING_KEYS.balance(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/billing/balance/{org}",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useTransactions(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...BILLING_KEYS.transactions(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/billing/transactions/{org}",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useUsageSeries(
  orgSlug: () => string | undefined,
  days: () => number,
) {
  return createQuery(() => ({
    queryKey: [...BILLING_KEYS.usageSeries(orgSlug()!, days())],
    queryFn: async () => {
      const client = createApiClient();
      const to = new Date();
      const from = new Date(to.getTime() - days() * 24 * 60 * 60 * 1000);
      const { data, error } = await client.GET(
        "/api/v0/billing/usage/{org}/series",
        {
          params: {
            path: { org: orgSlug()! },
            query: { from: from.toISOString(), to: to.toISOString() },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useUsageBreakdown(
  orgSlug: () => string | undefined,
  days: () => number,
) {
  return createQuery(() => ({
    queryKey: [...BILLING_KEYS.usageBreakdown(orgSlug()!, days())],
    queryFn: async () => {
      const client = createApiClient();
      const to = new Date();
      const from = new Date(to.getTime() - days() * 24 * 60 * 60 * 1000);
      const { data, error } = await client.GET(
        "/api/v0/billing/usage/{org}/breakdown",
        {
          params: {
            path: { org: orgSlug()! },
            query: { from: from.toISOString(), to: to.toISOString() },
          },
        },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useCheckout(orgSlug: () => string | undefined) {
  return createMutation(() => ({
    mutationFn: async (amount_cents: number) => {
      const client = createApiClient();
      const { data, error } = await client.POST(
        "/api/v0/billing/checkout/{org}",
        { params: { path: { org: orgSlug()! } }, body: { amount_cents } },
      );
      if (error) throw error;
      return data!;
    },
  }));
}

export function useRedeemCoupon(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (code: string) => {
      const client = createApiClient();
      const { data, error } = await client.POST(
        "/api/v0/billing/coupon/redeem/{org}",
        { params: { path: { org: orgSlug()! } }, body: { code } },
      );
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...BILLING_KEYS.balance(orgSlug()!)] });
      qc.invalidateQueries({ queryKey: [...BILLING_KEYS.transactions(orgSlug()!)] });
    },
  }));
}
