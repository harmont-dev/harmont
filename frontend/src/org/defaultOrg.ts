// The user's last-active organization slug, persisted so bare `/` can redirect
// to it (Vercel-style default org). A cookie (not localStorage) so a future
// server/edge redirect can read it too. Slugs are URL-safe; we validate on the
// way in and out to never trust a tampered cookie into routing.

const COOKIE = "harmont_org";
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
const ONE_YEAR = 60 * 60 * 24 * 365;

export function getDefaultOrg(): string | undefined {
  const match = document.cookie
    .split("; ")
    .find((c) => c.startsWith(`${COOKIE}=`));
  if (!match) return undefined;
  const value = decodeURIComponent(match.slice(COOKIE.length + 1));
  return SLUG_RE.test(value) ? value : undefined;
}

export function setDefaultOrg(slug: string): void {
  if (!SLUG_RE.test(slug)) return;
  document.cookie = `${COOKIE}=${encodeURIComponent(slug)}; max-age=${ONE_YEAR}; path=/; SameSite=Lax`;
}
