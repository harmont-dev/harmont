// Validates a post-auth redirect target. Only internal, same-origin absolute
// paths are allowed: anything that could resolve to a different host is dropped
// to "/" so a crafted `?redirect=` can't bounce the user (or a freshly minted
// CLI token) to an attacker-controlled origin. We've shipped an open-redirect
// bug in the OAuth path before — this is the gate that prevents a repeat.

const DEFAULT = "/";

export function safeRedirect(raw: string | null | undefined): string {
  if (typeof raw !== "string" || raw.length === 0) return DEFAULT;
  // Must be an absolute internal path.
  if (raw[0] !== "/") return DEFAULT;
  // Reject protocol-relative ("//host"), backslash ("/\\host"), and any C0
  // control char at index 1 — browsers (or other redirect consumers) may
  // normalize these into an authority, turning an "internal" path external.
  const second = raw.charCodeAt(1);
  if (raw[1] === "/" || raw[1] === "\\" || second <= 0x1f) return DEFAULT;
  return raw;
}
