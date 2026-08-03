import { http, HttpResponse } from "msw";
import {
  mockBalance,
  mockTransactions,
  mockUsage,
  mockUsageSeries,
} from "../data";

const BASE = "/api/v0";

const json = (body: Record<string, unknown> | Record<string, unknown>[]) =>
  HttpResponse.json(body, {
    headers: { "Content-Type": "application/json;charset=utf-8" },
  });

export const billingHandlers = [
  http.get(`${BASE}/billing/balance/:orgSlug`, async () => {
    return json(mockBalance);
  }),

  http.get(`${BASE}/billing/transactions/:orgSlug`, async () => {
    return json({ data: mockTransactions });
  }),

  http.get(`${BASE}/billing/usage/:orgSlug/series`, async ({ request }) => {
    const url = new URL(request.url);
    const from = new Date(url.searchParams.get("from") ?? Date.now());
    const to = new Date(url.searchParams.get("to") ?? Date.now());
    return json({ data: mockUsageSeries(from, to) });
  }),

  http.get(`${BASE}/billing/usage/:orgSlug`, async () => {
    return json(mockUsage);
  }),

  http.post(`${BASE}/billing/checkout/:orgSlug`, async () => {
    return json({ checkout_url: "https://checkout.stripe.com/c/pay/mock_session_test" });
  }),

  http.post(`${BASE}/billing/coupon/redeem/:orgSlug`, async ({ request }) => {
    const body = (await request.json()) as { code?: string };
    const code = (body.code ?? "").trim().toUpperCase();

    if (code === "USED") {
      return HttpResponse.json(
        { error: { code: "coupon_already_redeemed", type: "conflict", message: "This organization has already redeemed that coupon." } },
        { status: 409, headers: { "Content-Type": "application/json;charset=utf-8" } },
      );
    }
    if (code === "EXPIRED") {
      return HttpResponse.json(
        { error: { code: "coupon_unavailable", type: "invalid_request", message: "That coupon is expired or fully redeemed." } },
        { status: 422, headers: { "Content-Type": "application/json;charset=utf-8" } },
      );
    }

    const credit = 2500;
    mockBalance.balance_cents += credit;
    return json({ credit_cents: credit, balance_cents: mockBalance.balance_cents });
  }),
];
