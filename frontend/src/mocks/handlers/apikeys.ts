import { http, HttpResponse } from "msw";
import { mockApiKeys } from "../data";
import type {
  ApiKey,
  ApiKeyCreateRequest,
  ApiKeyCreateResponse,
} from "../../apikeys/types";

const BASE = "/api/v0";

const json = (body: Record<string, unknown>) =>
  HttpResponse.json(body, {
    headers: { "Content-Type": "application/json;charset=utf-8" },
  });

// Mutable working copy so create/revoke are reflected on the next list fetch,
// letting the reviewer see real state transitions in mock mode.
let keys: ApiKey[] = [...mockApiKeys];

// `crypto.randomUUID` only exists in a secure context (HTTPS / localhost); the
// dev box is reached over a plain-HTTP Tailscale IP, so use Math.random here.
const rid = () => Math.random().toString(36).slice(2);

export const apikeyHandlers = [
  http.get(`${BASE}/user/api-tokens`, () => json({ api_tokens: keys })),

  http.post(`${BASE}/user/api-tokens`, async ({ request }) => {
    const body = (await request.json()) as ApiKeyCreateRequest;
    const key: ApiKey = {
      id: "key-" + rid().slice(0, 8),
      description: body.description,
      created_at: new Date().toISOString(),
      expires_at: body.expires_at,
      last_used_at: null,
    };
    keys = [key, ...keys];
    const res: ApiKeyCreateResponse = {
      token: "hm_" + rid() + rid() + "MOCK",
      api_token: key,
    };
    return HttpResponse.json(res, {
      status: 201,
      headers: { "Content-Type": "application/json;charset=utf-8" },
    });
  }),

  http.delete(`${BASE}/user/api-tokens/:id`, ({ params }) => {
    keys = keys.filter((k) => k.id !== params.id);
    return new HttpResponse(null, { status: 204 });
  }),
];
