import createClient, { type Middleware } from "openapi-fetch";
import type { paths } from "./v1";
import { getToken, clearToken } from "../auth/token";

const baseUrl = import.meta.env.VITE_API_URL ?? "";

// Convergent Bearer-token auth: attach the stored session token as
// `Authorization: Bearer <token>` on every request when present. The API no
// longer uses cookies/sessions.
const bearerMiddleware: Middleware = {
  async onRequest({ request }) {
    const token = getToken();
    if (token) {
      request.headers.set("Authorization", `Bearer ${token}`);
    }
    return request;
  },
  async onResponse({ response }) {
    if (
      response.status === 401 &&
      !window.location.pathname.startsWith("/login")
    ) {
      // Token is stale/invalid: drop it and bounce to login, preserving where
      // the user was so /login can return them there after re-authenticating
      // (/login validates the redirect via safeRedirect).
      clearToken();
      const here = window.location.pathname + window.location.search;
      window.location.href = `/login?redirect=${encodeURIComponent(here)}`;
    }
    return undefined;
  },
};

export function createApiClient() {
  const client = createClient<paths>({ baseUrl });
  client.use(bearerMiddleware);
  return client;
}
