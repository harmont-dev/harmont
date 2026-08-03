import { execSync } from 'node:child_process';
import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

// This dev box is reached over Tailscale, so the browser's origin is the host's
// Tailscale IP, not localhost. Next 16 blocks cross-origin requests to dev
// resources (HMR, etc.) by default — which silently breaks client hydration
// (dead sidebar/search/collapse, while SSR links still work). Allow this host's
// Tailscale IP (mirroring scripts/dev-up.sh) plus any explicit
// ALLOWED_DEV_ORIGINS. Dev-only: skipped during production builds.
function devOrigins() {
  if (process.env.NODE_ENV === 'production') return [];
  const origins = new Set(
    (process.env.ALLOWED_DEV_ORIGINS?.split(',') ?? [])
      .map((s) => s.trim())
      .filter(Boolean),
  );
  try {
    const ip = execSync('tailscale ip -4', {
      stdio: ['ignore', 'pipe', 'ignore'],
    })
      .toString()
      .split('\n')[0]
      .trim();
    if (ip) origins.add(ip);
  } catch {
    // tailscale absent or not up — localhost dev still works.
  }
  return [...origins];
}

const allowedDevOrigins = devOrigins();

/** @type {import('next').NextConfig} */
const config = {
  output: 'standalone',
  reactStrictMode: true,
  // Standalone bundle traces files from the monorepo root by default; we keep
  // the docs-site self-contained so set the trace root to this package.
  outputFileTracingRoot: import.meta.dirname,
  // Agent-facing Markdown: `/cli/run.md` serves the Markdown body of `/cli/run`.
  async rewrites() {
    return [{ source: '/:path*.md', destination: '/llms.mdx/:path*' }];
  },
  ...(allowedDevOrigins.length > 0 ? { allowedDevOrigins } : {}),
};

export default withMDX(config);
