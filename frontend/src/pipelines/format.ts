/**
 * The short repo label shown as a pipeline's prefix: the last path segment of
 * the stored `owner/repo` repo name. Returns null when there is no repo name,
 * so callers can omit the prefix entirely.
 */
export function shortRepoName(
  repoName: string | null | undefined,
): string | null {
  if (!repoName) return null;
  const segments = repoName.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? null;
}
