// Centralized session-token store for the convergent Bearer-token auth model.
//
// The Elixir API issues a raw session bearer token from every login flow
// (OAuth, passkey login/signup, recovery). The SPA stores it here and the
// openapi-fetch middleware in `api/client.ts` attaches it as
// `Authorization: Bearer <token>` on every request. There is no cookie/session
// model anymore.

const TOKEN_KEY = "harmont_token";

export function getToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string): void {
  try {
    localStorage.setItem(TOKEN_KEY, token);
  } catch {
    // Storage unavailable (private mode / disabled): nothing we can do.
  }
}

export function clearToken(): void {
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch {
    // ignore
  }
}

export function hasToken(): boolean {
  return getToken() !== null;
}
