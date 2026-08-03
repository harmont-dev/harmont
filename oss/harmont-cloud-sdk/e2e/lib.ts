// Pure, network-free helpers for the e2e harness. Unit-tested in lib.test.ts.

const TERMINAL: ReadonlySet<string> = new Set(["passed", "failed", "canceled"]);

/** True once a build has reached a state it will never leave. */
export function isTerminal(state: string): boolean {
  return TERMINAL.has(state);
}

/**
 * A minimal valid v0 IR (`{"version":"0","steps":[...]}`, step fields
 * `type`/`key`/`cmd` per harmont_ir CommandStep).
 *
 * expectSource=false → source-independent command (works on the dev
 *   Backend.Local, which does NOT extract the uploaded tarball — wrinkle #4).
 * expectSource=true  → reads a file from the pushed repo; only passes on a
 *   real-VM (agent-mode) backend that materializes source.
 */
export function defaultIr(expectSource: boolean): string {
  const cmd = expectSource
    ? "cat harmont-e2e-marker.txt"
    : "echo harmont-e2e-ok";
  return JSON.stringify({
    version: "0",
    default_image: "ubuntu:24.04",
    steps: [{ type: "command", key: "e2e", cmd }],
  });
}
