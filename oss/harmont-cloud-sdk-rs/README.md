# harmont-cloud (Rust)

The Rust client for the [Harmont](https://harmont.dev) Cloud API.

Two crates:
- **`harmont-cloud-raw`** — generated from the OpenAPI spec by progenitor
  (`make codegen-sdk-rs`). One method per operation. Do not edit by hand.
- **`harmont-cloud`** — the high-level, hand-written surface you use: a
  `HarmontClient` with bearer auth, local-worktree build submission, status
  polling, live SSE log streaming, and the CLI auth flows.

The OpenAPI spec is the single source of truth; the raw crate is a regenerated
artifact (committed so the workspace builds without progenitor or network).
SSE log streaming is hand-written in `harmont-cloud` because it is not in the
spec.

## Usage

```rust
use harmont_cloud::{HarmontClient, builds::NewBuild};

#[tokio::main]
async fn main() -> harmont_cloud::Result<()> {
    let client = HarmontClient::new(std::env::var("HARMONT_API_TOKEN").unwrap());
    let build = client.submit_build(NewBuild {
        org: "acme".into(), pipeline: "ci".into(),
        branch: "feat/x".into(), commit: "abc123".into(),
        message: None,
        pipeline_ir: r#"{"version":"0","steps":[]}"#.into(),
        source_tgz: std::fs::read("worktree.tar.gz").unwrap(),
        env: Default::default(),
    }).await?;
    println!("build #{} \u{2192} {}", build.number, build.state);
    Ok(())
}
```

## Regenerating the raw client

```
make codegen-sdk-rs
```

This copies the committed `openapi.json` from the backend, sanitizes it, runs
progenitor, and restores the crate manifest + banner. The generated
`harmont-cloud-raw` is committed.

## Versioning

Mirrors the spec: minor = additive API, major = breaking, patch = SDK-only.
Published manually to crates.io.
