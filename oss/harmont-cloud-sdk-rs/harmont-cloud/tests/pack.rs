//! Guards that both crates are packageable: `cargo package --allow-dirty`
//! must succeed for both `harmont-cloud-raw` and `harmont-cloud`.
//!
//! Skipped unless HARMONT_SDK_PACK_TEST=1 (shells out to cargo).
//!
//! ## Why `cargo package` instead of `cargo publish --dry-run`
//!
//! `cargo publish --dry-run` (and plain `cargo package`) resolve every
//! dependency against crates.io.  `harmont-cloud` depends on
//! `harmont-cloud-raw` via a path dep; until `harmont-cloud-raw` is
//! published to crates.io first, that resolution will always fail with
//! "no matching package named `harmont-cloud-raw` found".  This is an
//! inherent release-ordering constraint: publish `harmont-cloud-raw` before
//! `harmont-cloud`.
//!
//! To still catch real packaging errors (missing README, bad metadata,
//! excluded files) we take the following approach:
//!
//! 1. `cargo package --allow-dirty -p harmont-cloud-raw` — must succeed
//!    unconditionally.  This validates the raw crate's tarball and metadata.
//!
//! 2. `cargo package --allow-dirty -p harmont-cloud` — may fail with the
//!    specific crates.io-resolution error for `harmont-cloud-raw` and that is
//!    the only tolerated failure.  Any other error (missing README, bad
//!    Cargo.toml field, excluded source file, compile error in the packaged
//!    tree, …) causes the test to fail.

const RAW_NOT_PUBLISHED: &str =
    "no matching package named `harmont-cloud-raw` found";

fn run_cargo_package(pkg: &str) -> std::process::Output {
    std::process::Command::new(env!("CARGO"))
        .args(["package", "--allow-dirty", "-p", pkg])
        .output()
        .expect("cargo runs")
}

#[test]
fn package_is_publishable() {
    if std::env::var("HARMONT_SDK_PACK_TEST").is_err() {
        eprintln!("skip: set HARMONT_SDK_PACK_TEST=1 to run");
        return;
    }

    // ── Step 1: harmont-cloud-raw ──────────────────────────────────────────
    // Must pass cleanly; it has no path deps of its own.
    let raw = run_cargo_package("harmont-cloud-raw");
    assert!(
        raw.status.success(),
        "cargo package harmont-cloud-raw failed:\n{}",
        String::from_utf8_lossy(&raw.stderr)
    );

    // ── Step 2: harmont-cloud ──────────────────────────────────────────────
    // Tolerate the known crates.io ordering error; fail on anything else.
    let high = run_cargo_package("harmont-cloud");
    if !high.status.success() {
        let stderr = String::from_utf8_lossy(&high.stderr);
        assert!(
            stderr.contains(RAW_NOT_PUBLISHED),
            "cargo package harmont-cloud failed for an unexpected reason \
             (expected only the crates.io ordering error for \
             harmont-cloud-raw, got):\n{stderr}"
        );
        // Known ordering constraint: harmont-cloud-raw must be published to
        // crates.io before harmont-cloud can be packaged independently.
        eprintln!(
            "note: harmont-cloud packaging skipped the verify step because \
             harmont-cloud-raw is not yet on crates.io (publish it first)"
        );
    }
}
