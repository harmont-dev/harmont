#!/usr/bin/env bash
# scripts/openapi-smoke.sh — verify api/openapi.json parses with both
# downstream codegen tools without producing them yet.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# 1. Validate as OpenAPI 3 with the official validator (requires npx).
npx --yes @redocly/cli@1 lint api/openapi.json

# 2. Probe progenitor's parser via a tiny Rust crate in /tmp.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Cargo.toml" <<EOF
[package]
name = "smoke"
version = "0.0.0"
edition = "2021"
[dependencies]
openapiv3 = "2"
serde_json = "1"
EOF
mkdir -p "$WORK/src"
cat > "$WORK/src/main.rs" <<'EOF'
fn main() {
    let s = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let _: openapiv3::OpenAPI = serde_json::from_str(&s).expect("parse failed");
    println!("openapi parse OK");
}
EOF
cargo run --quiet --manifest-path "$WORK/Cargo.toml" -- "$PWD/api/openapi.json"
