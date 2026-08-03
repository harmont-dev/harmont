//! Agent-wide error type. Mapped to process exit codes in main.

use thiserror::Error;

#[allow(dead_code)]
#[derive(Error, Debug)]
pub enum AgentError {
    #[error("config: {0}")]
    Config(String),

    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("spool: {0}")]
    Spool(String),

    #[error("source fetch: {0}")]
    Source(String),

    #[error("protocol: {0}")]
    Protocol(String),

    #[error("child: {0}")]
    Child(String),
}

/// Mapping from agent failure to process exit code. See spec §8.
#[allow(dead_code)]
pub fn exit_code_for(err: &AgentError) -> i32 {
    match err {
        AgentError::Config(_) => 64,        // EX_USAGE
        AgentError::Source(_) => 3,
        AgentError::Spool(_) => 5,
        _ => 1,
    }
}
