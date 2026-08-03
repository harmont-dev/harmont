import { isMarkdownPreferred } from 'fumadocs-core/negotiation';
import { NextResponse, type NextRequest } from 'next/server';

export function middleware(request: NextRequest): NextResponse {
  const { pathname } = request.nextUrl;

  if (isMarkdownPreferred(request)) {
    const url = request.nextUrl.clone();
    url.pathname = `/llms.mdx${pathname === '/' ? '' : pathname}`;
    const res = NextResponse.rewrite(url);
    res.headers.set('Vary', 'Accept');
    return res;
  }

  // Browser/HTML path: still advertise that the representation varies by Accept
  // so a shared cache never hands an agent a cached HTML page (or vice versa).
  const res = NextResponse.next();
  res.headers.set('Vary', 'Accept');
  return res;
}

export const config = {
  // Run only on doc pages. Skip Next internals, API routes, the llms.* routes
  // themselves, and any request whose LAST path segment has a file extension
  // (assets, *.md, *.txt) — `\.[^/]*$` anchors the dot to the final segment so
  // a doc URL with a dot in an earlier segment (e.g. /sdk/v1.0/foo) still
  // negotiates.
  matcher: ['/((?!_next/|api/|llms\\.mdx|llms\\.txt|llms-full\\.txt|.*\\.[^/]*$).*)'],
};
