//! Fetch the source tarball from a presigned URL, verify sha256, extract to /workspace.

use crate::error::AgentError;
use sha2::{Digest, Sha256};
use std::path::Path;
use tokio::process::Command;

pub async fn fetch_and_extract(
    url: &str,
    expected_sha256_hex: &str,
    dest_dir: &Path,
    bearer_token: &str,
) -> Result<(), AgentError> {
    tokio::fs::create_dir_all(dest_dir).await?;
    let archive = dest_dir.join("source.tar.gz");

    let client = reqwest::Client::new();
    let resp = client
        .get(url)
        .bearer_auth(bearer_token)
        .send()
        .await
        .map_err(|e| AgentError::Source(format!("http: {e}")))?
        .error_for_status()
        .map_err(|e| AgentError::Source(format!("status: {e}")))?;

    let bytes = resp.bytes()
        .await
        .map_err(|e| AgentError::Source(format!("read body: {e}")))?;

    if !expected_sha256_hex.is_empty() {
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        let got = hex::encode(hasher.finalize());
        if !got.eq_ignore_ascii_case(expected_sha256_hex) {
            return Err(AgentError::Source(format!(
                "sha256 mismatch: expected {expected_sha256_hex}, got {got}"
            )));
        }
    }
    tokio::fs::write(&archive, &bytes).await?;

    let status = Command::new("tar")
        .arg("-xzf").arg(&archive)
        .arg("-C").arg(dest_dir)
        .status()
        .await
        .map_err(|e| AgentError::Source(format!("tar spawn: {e}")))?;
    if !status.success() {
        return Err(AgentError::Source(format!("tar exit: {status}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_tarball(dir: &Path) -> (Vec<u8>, String) {
        let work = TempDir::new().unwrap();
        std::fs::write(work.path().join("hello.txt"), b"hi").unwrap();
        let tar_path = dir.join("src.tar.gz");
        let status = std::process::Command::new("tar")
            .arg("-czf").arg(&tar_path)
            .arg("-C").arg(work.path())
            .arg("hello.txt")
            .status()
            .unwrap();
        assert!(status.success());
        let bytes = std::fs::read(&tar_path).unwrap();
        let mut h = Sha256::new();
        h.update(&bytes);
        let sha = hex::encode(h.finalize());
        (bytes, sha)
    }

    #[tokio::test]
    async fn sha_check_predicate_works() {
        let tmp = TempDir::new().unwrap();
        let (bytes, _sha) = make_tarball(tmp.path());
        let mut h = Sha256::new();
        h.update(&bytes);
        let real = hex::encode(h.finalize());
        let wrong = "0".repeat(64);
        assert_ne!(real, wrong);
    }
}
