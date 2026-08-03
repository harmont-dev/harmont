# harmont-agent

In-VM job runner for Harmont. Single static musl binary. Runs as the
VM entrypoint (set via Freestyle base snapshot) and owns the job's
lifecycle: source fetch, command exec, log streaming over WebSocket +
protobuf, heartbeat, cancel/timeout.

See `proto/agent.proto` for the wire schema.

## Build

    cargo build                              # debug
    cargo build --release \
      --target x86_64-unknown-linux-musl     # production binary

## Test

    cargo test
    cargo clippy --all-targets -- -D warnings

## Run locally

The agent is normally launched by Freestyle's VM init. To run locally
against a dev `harmont-api`:

    cargo run -- \
      --build-id <uuid> \
      --job-id   <uuid> \
      --api-url  http://localhost:3000 \
      --token    <runner-token>

## Distribution

The release binary is baked into the job-VM base image alongside the `hm`
renderer, re-baked from the current commit at deploy time so a VM never boots a
stale agent.
