import { http, HttpResponse } from "msw";
import { mockOrg, mockOrganizations } from "../data";

const BASE = "/api/v0";

const json = (body: Record<string, unknown>) =>
  HttpResponse.json(body, {
    headers: { "Content-Type": "application/json;charset=utf-8" },
  });

export const orgHandlers = [
  http.get(`${BASE}/organizations`, async () =>
    json({ data: mockOrganizations, next_cursor: null }),
  ),
  http.get(`${BASE}/organizations/:org`, async () => {
    return json(mockOrg);
  }),
];
