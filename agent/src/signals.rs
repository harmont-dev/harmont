//! Coordinator that consumes Cancel or Timeout signals and walks SIGTERM → grace → SIGKILL.

use crate::child::ChildHandle;
use crate::error::AgentError;
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use std::time::Duration;
use tokio::sync::watch;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminationReason {
    Cancel,
    Timeout,
}

pub struct Supervisor {
    pub cancel_rx: watch::Receiver<bool>,
    pub timeout_rx: watch::Receiver<bool>,
    pub grace: Duration,
}

impl Supervisor {
    /// Watches both signals. On the first one, sends SIGTERM to the
    /// child's process group, waits `grace`, then SIGKILL if needed.
    /// Resolves once the child is reaped.
    pub async fn enforce(
        mut self,
        handle: &mut ChildHandle,
    ) -> Result<Option<TerminationReason>, AgentError> {
        let pgid = -handle.pgid;
        let reason = tokio::select! {
            biased;
            _ = self.cancel_rx.changed() => Some(TerminationReason::Cancel),
            _ = self.timeout_rx.changed() => Some(TerminationReason::Timeout),
            status = handle.child.wait() => {
                status.map_err(|e| AgentError::Child(e.to_string()))?;
                return Ok(None);
            }
        };

        // Send SIGTERM to the entire process group.
        let _ = kill(Pid::from_raw(pgid), Signal::SIGTERM);

        // Wait up to `grace` for the child to exit gracefully.
        let killed_gracefully = tokio::time::timeout(self.grace, handle.child.wait()).await;

        if killed_gracefully.is_err() {
            // Still alive — escalate.
            let _ = kill(Pid::from_raw(pgid), Signal::SIGKILL);
            let _ = handle.child.wait().await;
        }

        Ok(reason)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::child::{spawn, SpawnRequest};
    use std::collections::HashMap;
    use tempfile::TempDir;

    #[tokio::test]
    async fn cancel_kills_long_running_child_within_grace() {
        let tmp = TempDir::new().unwrap();
        let mut handle = spawn(SpawnRequest {
            command: "sleep 30".into(),
            env: HashMap::new(),
            cwd: tmp.path().to_path_buf(),
        }).await.unwrap();

        let (c_tx, c_rx) = watch::channel(false);
        let (_t_tx, t_rx) = watch::channel(false);

        let sup = Supervisor {
            cancel_rx: c_rx,
            timeout_rx: t_rx,
            grace: Duration::from_millis(500),
        };

        let start = std::time::Instant::now();
        let task = tokio::spawn(async move { sup.enforce(&mut handle).await });
        c_tx.send(true).unwrap();
        let outcome = task.await.unwrap().unwrap();

        assert_eq!(outcome, Some(TerminationReason::Cancel));
        assert!(start.elapsed() < Duration::from_secs(3), "took too long: {:?}", start.elapsed());
    }

    #[tokio::test]
    async fn natural_exit_returns_none() {
        let tmp = TempDir::new().unwrap();
        let mut handle = spawn(SpawnRequest {
            command: "exit 0".into(),
            env: HashMap::new(),
            cwd: tmp.path().to_path_buf(),
        }).await.unwrap();

        let (_c_tx, c_rx) = watch::channel(false);
        let (_t_tx, t_rx) = watch::channel(false);

        let sup = Supervisor {
            cancel_rx: c_rx,
            timeout_rx: t_rx,
            grace: Duration::from_millis(500),
        };
        let outcome = sup.enforce(&mut handle).await.unwrap();
        assert_eq!(outcome, None);
    }
}
