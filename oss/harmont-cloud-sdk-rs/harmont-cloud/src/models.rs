//! Ergonomic re-exports of generated model types plus small helpers.

pub use harmont_cloud_raw::types::{Build, Job, CreateBuildRequest, CreateRepoBuildRequest};

/// Whether a build state is terminal (no further transitions).
pub fn build_is_terminal(state: &str) -> bool {
    matches!(state, "passed" | "failed" | "canceled")
}

/// Whether a job state is terminal.
pub fn job_is_terminal(state: &str) -> bool {
    matches!(state, "passed" | "failed" | "skipped" | "canceled" | "timed_out")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_build_states() {
        assert!(build_is_terminal("passed"));
        assert!(!build_is_terminal("running"));
    }

    #[test]
    fn terminal_job_states() {
        assert!(job_is_terminal("timed_out"));
        assert!(!job_is_terminal("running"));
    }
}
