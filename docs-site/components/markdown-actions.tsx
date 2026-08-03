'use client';

import { useRef, useState, type ReactNode } from 'react';

/**
 * Page-level affordance: copy or open the agent-facing Markdown of this page.
 * Rendered as compact icon buttons inline with the page title. `mdUrl` is the
 * page URL with `.md` appended (e.g. "/cli/run.md").
 */
export function MarkdownActions({ mdUrl }: { mdUrl: string }) {
  const [status, setStatus] = useState<'idle' | 'copied' | 'failed'>('idle');
  // Identifies the latest click so a stale timer from an earlier click can't
  // reset the label while newer feedback is showing.
  const clickId = useRef(0);

  async function copy() {
    const id = ++clickId.current;
    try {
      const res = await fetch(mdUrl);
      if (!res.ok) throw new Error(`fetch ${mdUrl} returned ${res.status}`);
      await navigator.clipboard.writeText(await res.text());
      setStatus('copied');
    } catch {
      // Surface the failure instead of leaving a dead button — the "view"
      // link stays available as the fallback.
      setStatus('failed');
    }
    setTimeout(() => {
      if (clickId.current === id) setStatus('idle');
    }, 2000);
  }

  const copyTitle =
    status === 'copied'
      ? 'Copied'
      : status === 'failed'
        ? 'Copy failed'
        : 'Copy as Markdown';

  return (
    <div className="not-prose flex shrink-0 items-center gap-0.5">
      <button type="button" onClick={copy} aria-label={copyTitle} title={copyTitle} className={btn}>
        {status === 'copied' ? <CheckIcon /> : status === 'failed' ? <XIcon /> : <CopyIcon />}
      </button>
      <a href={mdUrl} aria-label="View as Markdown" title="View as Markdown" className={btn}>
        <FileIcon />
      </a>
    </div>
  );
}

const btn =
  'rounded-md p-1.5 text-fd-muted-foreground transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground';

function Svg({ children }: { children: ReactNode }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="size-4"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

function CopyIcon() {
  return (
    <Svg>
      <rect width="14" height="14" x="8" y="8" rx="2" ry="2" />
      <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
    </Svg>
  );
}

function CheckIcon() {
  return (
    <Svg>
      <path d="M20 6 9 17l-5-5" />
    </Svg>
  );
}

function XIcon() {
  return (
    <Svg>
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </Svg>
  );
}

function FileIcon() {
  return (
    <Svg>
      <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z" />
      <path d="M14 2v4a2 2 0 0 0 2 2h4" />
      <path d="M10 9H8" />
      <path d="M16 13H8" />
      <path d="M16 17H8" />
    </Svg>
  );
}
