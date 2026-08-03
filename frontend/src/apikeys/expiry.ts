// Pure mapping from the create form's expiry choice to the `expires_at`
// value the API expects. Kept side-effect-free (clock injected) so it's
// unit-testable, matching the repo's pure-helper test convention.

export type ExpiryOption = "never" | "30d" | "90d";

export const EXPIRY_OPTIONS: { value: ExpiryOption; label: string }[] = [
  { value: "never", label: "Never" },
  { value: "30d", label: "30 days" },
  { value: "90d", label: "90 days" },
];

const DAYS: Record<Exclude<ExpiryOption, "never">, number> = {
  "30d": 30,
  "90d": 90,
};

/** Returns the ISO-8601 expiry for `option`, or null for "never". */
export function expiryToIso(
  option: ExpiryOption,
  now: Date = new Date(),
): string | null {
  if (option === "never") return null;
  const ms = DAYS[option] * 24 * 60 * 60 * 1000;
  return new Date(now.getTime() + ms).toISOString();
}
