//! Child process spawn + stdout/stderr capture.
//! Spawns `bash -c "<cmd>"` in its own process group so signals reach descendants.

use crate::error::AgentError;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child as TokioChild, Command};
use tokio::sync::mpsc;

pub struct ChildHandle {
    pub child: TokioChild,
    pub pgid: i32,
    pub stdout_lines: mpsc::Receiver<LineEvent>,
    pub stderr_lines: mpsc::Receiver<LineEvent>,
}

#[derive(Debug, Clone)]
pub struct LineEvent {
    pub bytes: Vec<u8>,
}

pub struct SpawnRequest {
    pub command: String,
    pub env: HashMap<String, String>,
    pub cwd: PathBuf,
}

pub async fn spawn(req: SpawnRequest) -> Result<ChildHandle, AgentError> {
    let mut cmd = Command::new("bash");
    cmd.arg("-c").arg(&req.command);
    cmd.current_dir(&req.cwd);
    cmd.env_clear();
    // A bare environment breaks tools that assume HOME/PATH — e.g. rustup's
    // `. "$HOME/.cargo/env"` becomes `. "/.cargo/env"` and fails. Seed a sane
    // base, then let the job's own env override it. The agent runs as root
    // (sudo -n -H), so HOME defaults to /root where rustup/uv install.
    let home = std::env::var("HOME")
        .ok()
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "/root".to_string());
    let path = std::env::var("PATH")
        .ok()
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| {
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".to_string()
        });
    cmd.env("HOME", home);
    cmd.env("PATH", path);
    for (k, v) in &req.env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    // Put the child in its own process group so we can signal the whole group.
    unsafe {
        cmd.pre_exec(|| {
            nix::unistd::setpgid(nix::unistd::Pid::from_raw(0), nix::unistd::Pid::from_raw(0))
                .map_err(|e| std::io::Error::from_raw_os_error(e as i32))?;
            Ok(())
        });
    }

    let mut child = cmd.spawn().map_err(|e| AgentError::Child(e.to_string()))?;
    let pid = child.id().ok_or_else(|| AgentError::Child("no pid".into()))? as i32;

    let (stdout_tx, stdout_rx) = mpsc::channel(256);
    let (stderr_tx, stderr_rx) = mpsc::channel(256);

    let stdout = child.stdout.take().ok_or_else(|| AgentError::Child("no stdout pipe".into()))?;
    tokio::spawn(forward_lines(BufReader::new(stdout), stdout_tx));

    let stderr = child.stderr.take().ok_or_else(|| AgentError::Child("no stderr pipe".into()))?;
    tokio::spawn(forward_lines(BufReader::new(stderr), stderr_tx));

    Ok(ChildHandle {
        child,
        pgid: pid,
        stdout_lines: stdout_rx,
        stderr_lines: stderr_rx,
    })
}

async fn forward_lines<R: tokio::io::AsyncRead + Unpin>(
    mut reader: BufReader<R>,
    tx: mpsc::Sender<LineEvent>,
) {
    let mut buf = Vec::with_capacity(4096);
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) => return,
            Ok(_) => {
                let ev = LineEvent {
                    bytes: buf.clone(),
                };
                if tx.send(ev).await.is_err() {
                    return;
                }
            }
            Err(_) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn captures_stdout_lines() {
        let tmp = TempDir::new().unwrap();
        let mut handle = spawn(SpawnRequest {
            command: "echo hello; echo world".into(),
            env: HashMap::new(),
            cwd: tmp.path().to_path_buf(),
        }).await.expect("spawn");

        let mut got: Vec<Vec<u8>> = Vec::new();
        while let Some(ev) = handle.stdout_lines.recv().await {
            got.push(ev.bytes);
            if got.len() == 2 { break; }
        }
        let status = handle.child.wait().await.unwrap();
        assert!(status.success());
        assert_eq!(got[0], b"hello\n");
        assert_eq!(got[1], b"world\n");
    }

    #[tokio::test]
    async fn captures_stderr_separately() {
        let tmp = TempDir::new().unwrap();
        let mut handle = spawn(SpawnRequest {
            command: "echo to-stdout; echo to-stderr 1>&2".into(),
            env: HashMap::new(),
            cwd: tmp.path().to_path_buf(),
        }).await.expect("spawn");

        let out = handle.stdout_lines.recv().await.unwrap();
        let err = handle.stderr_lines.recv().await.unwrap();
        let _ = handle.child.wait().await.unwrap();

        assert_eq!(out.bytes, b"to-stdout\n");
        assert_eq!(err.bytes, b"to-stderr\n");
    }

    #[tokio::test]
    async fn spawn_seeds_home_and_path_and_overlays_job_env() {
        use std::collections::HashMap;
        let mut env = HashMap::new();
        env.insert("CI".to_string(), "true".to_string());
        let mut h = spawn(SpawnRequest {
            command: "echo \"H=$HOME P=${PATH:+set} CI=$CI\"".to_string(),
            env,
            cwd: std::env::temp_dir(),
        })
        .await
        .expect("spawn");
        let line = h.stdout_lines.recv().await.expect("a line");
        let s = String::from_utf8_lossy(&line.bytes).to_string();
        assert!(s.contains("H=/"), "HOME should be an absolute path: {s}");
        assert!(!s.contains("H= "), "HOME must not be empty: {s}");
        assert!(s.contains("P=set"), "PATH must be set: {s}");
        assert!(s.contains("CI=true"), "job env must overlay: {s}");
    }

    #[tokio::test]
    async fn returns_nonzero_exit_code() {
        let tmp = TempDir::new().unwrap();
        let mut handle = spawn(SpawnRequest {
            command: "exit 42".into(),
            env: HashMap::new(),
            cwd: tmp.path().to_path_buf(),
        }).await.expect("spawn");
        let status = handle.child.wait().await.unwrap();
        assert_eq!(status.code(), Some(42));
    }
}
