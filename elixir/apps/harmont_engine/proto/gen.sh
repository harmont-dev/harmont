#!/usr/bin/env bash
# Regenerate Elixir protobuf stubs. Run from elixir/apps/harmont_engine/.
# Only agent.proto remains (the VM<->agent WebSocket frames); the api<->executor
# gRPC service was deleted in Plan 6, so there is no gRPC plugin here.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=lib/harmont/proto
mkdir -p "$OUT"

# Where the *.proto sources live. Defaults to the in-repo sibling path used by
# `make build` / local `mix proto.gen`. The backend Dockerfile COPYs proto to
# /proto, so it overrides this to PROTO_DIR=/proto.
PROTO_DIR="${PROTO_DIR:-../../../proto}"

# `mix protobuf.generate` compiles the project before generating. On a clean tree
# (the stubs are gitignored — see .gitignore), the modules that USE the stubs can't
# compile yet, deadlocking the generator. HARMONT_PROTO_GEN=1 makes mix.exs restrict
# elixirc_paths to just the proto dir for this call, breaking the cycle.
export HARMONT_PROTO_GEN=1

# Pass the proto file RELATIVE to --include-path (bare "agent.proto"), NOT
# prefixed with $PROTO_DIR. protoc records the descriptor name relative to the
# include path ("agent.proto") and protobuf_generate matches the file arg
# against that name. Prefixing it ("$PROTO_DIR/agent.proto") mismatches whenever
# protobuf_generate's normalize_import_paths takes its File.exists? branch — as
# in the Docker build, where CWD (/app/apps/harmont_engine) is shallow enough
# that the doubled "../../../" clamps at / and Path.join resolves back onto the
# real /proto/agent.proto, so the unnormalized prefixed path is kept and never
# matches protoc's "agent.proto". Bare "agent.proto" matches in both branches,
# making codegen independent of CWD depth and of relative-vs-absolute PROTO_DIR.
mix protobuf.generate \
  --output-path="$OUT" \
  --include-path="$PROTO_DIR" \
  agent.proto

mix format "$OUT/*.pb.ex"
echo "proto codegen done -> $OUT"
