import type { components } from "./v1";

// The error-response envelope every harmont-api endpoint returns on failure.
// openapi-fetch surfaces the parsed response body as the thrown/`error` value,
// so callers receive THIS object — not a JS `Error`. The type is generated
// from the OpenApiSpex spec the Elixir API emits
// (elixir/apps/harmont_api/priv/static/openapi.json -> v1.d.ts via
// `npm run codegen`); errors.ts only adds the runtime accessors.
export type ApiErrorEnvelope = components["schemas"]["Error"];

export function isApiError(e: unknown): e is ApiErrorEnvelope {
  if (typeof e !== "object" || e === null || !("error" in e)) return false;
  const body = (e as ApiErrorEnvelope).error;
  return typeof body === "object" && body !== null && typeof body.message === "string";
}

/** Human-facing message for any thrown value: API envelope, JS `Error`
 *  (including WebAuthn DOMExceptions), plain string, or unknown. */
export function apiErrorMessage(e: unknown, fallback = "Something went wrong."): string {
  if (isApiError(e)) return e.error.message;
  if (e instanceof Error && e.message) return e.message;
  if (typeof e === "string" && e.length > 0) return e;
  return fallback;
}

/** Stable machine code: the envelope `code` (e.g. "passkey_unknown_credential")
 *  or, for a real Error, its `name` (e.g. "NotAllowedError"). */
export function apiErrorCode(e: unknown): string | undefined {
  if (isApiError(e)) return e.error.code;
  if (e instanceof Error && e.name) return e.name;
  return undefined;
}

export function apiErrorDocUrl(e: unknown): string | undefined {
  return isApiError(e) ? e.error.doc_url : undefined;
}

/** A field off the envelope body not in the base schema (e.g. an extra
 *  context field an error attaches alongside the canonical envelope keys). */
export function apiErrorField(e: unknown, key: string): string | undefined {
  if (!isApiError(e)) return undefined;
  const v = (e.error as Record<string, unknown>)[key];
  return typeof v === "string" ? v : undefined;
}

/** WebAuthn ceremony cancellation — the user dismissed the OS passkey prompt.
 *  simplewebauthn rethrows the DOMException unchanged. Treat as a silent no-op,
 *  not an error to surface. */
export function isWebauthnCancel(e: unknown): boolean {
  return e instanceof Error && e.name === "NotAllowedError";
}
