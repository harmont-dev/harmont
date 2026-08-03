# Harmont agent ↔ API protocol

`agent.proto` is the wire schema between `harmont-agent` (Rust, in-VM) and
the Elixir backend umbrella (terminated by `harmont_web`). It is the source
of truth.

## Transport

WebSocket. Endpoint: `wss://api.harmont.dev/v0/agent/connect`.

Authentication: standard HTTP `Authorization: Bearer <runner-token>` header
on the upgrade request.

Each WebSocket binary frame contains exactly one encoded protobuf message:

  - client → server: an encoded `AgentFrame`
  - server → client: an encoded `ServerFrame`

WebSocket framing makes lengths and message boundaries explicit, so no
length prefix appears in the protobuf payload.

Text frames, ping/pong, and close frames follow the WebSocket spec.
Connections idle for > 60s without traffic should ping to keep proxies
happy; the agent sends application-level `Heartbeat` frames every 5s
so this is mostly automatic.

## Codegen

### Rust

`agent/build.rs` invokes `prost-build` automatically on `cargo build`.
Output lives under `agent/target/`. Never edit generated code; edit
this file.

### Elixir

The Elixir stubs under `elixir/apps/harmont_engine/lib/harmont/proto/`
are gitignored and regenerated from `agent.proto` by
`elixir/apps/harmont_engine/proto/gen.sh`. Regenerate with:

    make codegen-proto   # runs `mix proto.gen`

## Backwards compatibility

This is a v1 schema. Additive-only changes within v1:

  - new fields with new tag numbers
  - new enum values (with reserved tags for removed ones)
  - new top-level messages

Breaking changes bump `proto_version` in `HelloMsg`. Server rejects
agents below `appAgentRequiredProtoVersion`.
