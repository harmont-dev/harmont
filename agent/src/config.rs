//! Agent configuration: CLI flags + env vars.

use crate::error::AgentError;
use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug, Clone)]
#[command(name = "harmont-agent", version)]
pub struct AgentConfig {
    #[arg(long, env = "HARMONT_BUILD_ID")]
    pub build_id: String,

    #[arg(long, env = "HARMONT_JOB_ID")]
    pub job_id: String,

    #[arg(long, env = "HARMONT_API_URL")]
    pub api_url: String,

    /// Runner token, inline. Prefer `--token-file`: an inline token (env var or
    /// argv) is readable via `/proc` by every child process of this job. Kept
    /// for backward compatibility with bootstraps that predate `--token-file`.
    #[arg(long, env = "HARMONT_TOKEN")]
    pub token: Option<String>,

    /// Path to a file containing the runner token (typically a 0600 tmpfile the
    /// bootstrap writes). Takes precedence over `--token`. The file's trailing
    /// whitespace is trimmed.
    #[arg(long, env = "HARMONT_TOKEN_FILE")]
    pub token_file: Option<PathBuf>,

    #[arg(long, env = "HARMONT_AGENT_SPOOL_DIR", default_value = "/var/lib/harmont-agent")]
    pub spool_dir: PathBuf,

    #[arg(long, env = "HARMONT_AGENT_MAX_SPOOL_BYTES", default_value_t = 268_435_456)]
    pub max_spool_bytes: u64,

    #[arg(long, env = "HARMONT_AGENT_ABORT_DISCO_SEC", default_value_t = 300)]
    pub abort_after_disconnect_sec: u64,

    #[arg(long, env = "HARMONT_AGENT_HEARTBEAT_SEC", default_value_t = 5)]
    pub heartbeat_interval_sec: u64,
}

impl AgentConfig {
    /// Resolve the runner token. `--token-file` wins over `--token`; reading
    /// from a file keeps the secret out of argv and the process environment
    /// (both readable via `/proc`). Trailing newline/whitespace is trimmed so a
    /// `printf '%s'`-written or here-doc'd file both work.
    pub fn resolve_token(&self) -> Result<String, AgentError> {
        if let Some(path) = &self.token_file {
            let raw = std::fs::read_to_string(path).map_err(|e| {
                AgentError::Config(format!("reading --token-file {}: {e}", path.display()))
            })?;
            let tok = raw.trim_end().to_string();
            if tok.is_empty() {
                return Err(AgentError::Config(format!(
                    "--token-file {} is empty",
                    path.display()
                )));
            }
            return Ok(tok);
        }
        self.token.clone().ok_or_else(|| {
            AgentError::Config("no runner token: pass --token-file (preferred) or --token".into())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_required_args() {
        let cfg = AgentConfig::try_parse_from([
            "harmont-agent",
            "--build-id", "b1",
            "--job-id", "j1",
            "--api-url", "https://api.example",
            "--token", "tok",
        ]).expect("parse should succeed");
        assert_eq!(cfg.build_id, "b1");
        assert_eq!(cfg.job_id, "j1");
        assert_eq!(cfg.api_url, "https://api.example");
        assert_eq!(cfg.resolve_token().expect("token resolves"), "tok");
        assert_eq!(cfg.max_spool_bytes, 268_435_456);
        assert_eq!(cfg.abort_after_disconnect_sec, 300);
    }

    #[test]
    fn fails_without_required() {
        let r = AgentConfig::try_parse_from(["harmont-agent"]);
        assert!(r.is_err());
    }

    #[test]
    fn token_file_takes_precedence_and_is_trimmed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tok");
        std::fs::write(&path, "file-secret\n").unwrap();
        let cfg = AgentConfig::try_parse_from([
            "harmont-agent",
            "--build-id", "b1",
            "--job-id", "j1",
            "--api-url", "https://api.example",
            "--token", "inline-secret",
            "--token-file", path.to_str().unwrap(),
        ])
        .expect("parse should succeed");
        // --token-file wins over --token, and the trailing newline is trimmed.
        assert_eq!(cfg.resolve_token().expect("token resolves"), "file-secret");
    }

    #[test]
    fn resolve_token_errors_when_neither_source_present() {
        let cfg = AgentConfig::try_parse_from([
            "harmont-agent",
            "--build-id", "b1",
            "--job-id", "j1",
            "--api-url", "https://api.example",
        ])
        .expect("parse should succeed");
        assert!(cfg.resolve_token().is_err());
    }

    #[test]
    fn resolve_token_errors_on_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tok");
        std::fs::write(&path, "  \n").unwrap();
        let cfg = AgentConfig::try_parse_from([
            "harmont-agent",
            "--build-id", "b1",
            "--job-id", "j1",
            "--api-url", "https://api.example",
            "--token-file", path.to_str().unwrap(),
        ])
        .expect("parse should succeed");
        assert!(cfg.resolve_token().is_err());
    }
}
