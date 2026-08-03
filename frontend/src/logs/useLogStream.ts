import { createSignal, createEffect, onCleanup } from "solid-js";

export type LogStreamState =
  | { status: "idle" }
  | { status: "connecting" }
  | { status: "streaming"; content: string }
  | { status: "done"; content: string }
  | { status: "error"; content: string; message: string };

// A single log chunk as rendered by the backend SSE server.
// `seq` is the monotonic per-job sequence number; `content` is the text.
export interface LogChunk {
  seq: number;
  content: string;
}

// Accumulates log text across the SSE lifecycle, including reconnects.
//
// The server emits one `history` frame (a replay) followed by per-chunk
// `chunk` frames carrying `id: <seq>`. On reconnect the browser auto-sends
// `Last-Event-ID`, so the server replays a FRESH `history` containing only the
// post-cursor chunks. A naive overwrite of the visible text on every `history`
// would therefore wipe everything the user already saw down to that delta.
//
// We instead track the highest seq applied and only append chunks we haven't
// seen — so both the initial `history` and any resume `history` (and the
// interleaved `chunk` frames) are idempotent and order-preserving.
//
// Memory: `content` is an unbounded string for the job's lifetime. Acceptable
// for now — a single job's log is bounded by the agent's output. If this ever
// backs a long-lived/very-chatty stream, cap it (e.g. keep the last N bytes /
// virtualize the viewer) rather than holding the whole buffer here.
export class LogAccumulator {
  private content = "";
  // Highest seq already folded into `content`. -1 means nothing applied yet,
  // which is correct because the lowest real seq is 0.
  private hwm = -1;

  // Folds a batch of chunks (from a `history` replay or a single `chunk`
  // frame) into the buffer, appending only those with seq beyond the
  // high-water-mark. Returns the current full content.
  apply(chunks: LogChunk[]): string {
    for (const c of chunks) {
      if (c.seq > this.hwm) {
        this.content += c.content;
        this.hwm = c.seq;
      }
    }
    return this.content;
  }

  text(): string {
    return this.content;
  }
}

export function useLogStream(
  jobId: () => string | undefined,
  token: () => string | undefined,
  apiUrl: () => string,
) {
  const [state, setState] = createSignal<LogStreamState>({ status: "idle" });

  createEffect(() => {
    const jid = jobId();
    const tok = token();
    const base = apiUrl();
    if (!jid || !tok) {
      setState({ status: "idle" });
      return;
    }

    setState({ status: "connecting" });
    const acc = new LogAccumulator();
    // Set once the server cleanly closes the stream (EOF). The browser's
    // EventSource auto-reconnects on a transport drop, so a CLOSED readyState
    // only means "no more data is coming" when the server itself ended it —
    // which it does on normal job completion. We treat that as success.
    let serverClosed = false;

    const url = `${base}/v0/jobs/${jid}/logs?token=${tok}`;
    const es = new EventSource(url);

    es.addEventListener("history", (e) => {
      const data = JSON.parse(e.data);
      const content = acc.apply(data.chunks as LogChunk[]);
      setState({ status: "streaming", content });
    });

    es.addEventListener("chunk", (e) => {
      const data = JSON.parse(e.data) as LogChunk;
      const content = acc.apply([data]);
      setState({ status: "streaming", content });
    });

    // The server signals a clean end-of-log with an explicit `done` event so
    // we can distinguish normal completion from a transport failure.
    es.addEventListener("done", () => {
      serverClosed = true;
      es.close();
      setState({ status: "done", content: acc.text() });
    });

    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) {
        // A CLOSED stream after a clean `done` is success, not failure.
        if (serverClosed) {
          setState({ status: "done", content: acc.text() });
        } else {
          setState({
            status: "error",
            content: acc.text(),
            message: "Log stream closed",
          });
        }
      }
      // readyState CONNECTING here means the browser is auto-reconnecting;
      // leave the visible content in place and wait for the resume `history`.
    };

    onCleanup(() => {
      es.close();
    });
  });

  return state;
}
