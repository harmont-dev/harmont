//! harmont-agent — in-VM job runner. See proto/agent.proto for the wire schema.

use clap::Parser;
use harmont_agent::config::AgentConfig;
use harmont_agent::error::{exit_code_for, AgentError};
use harmont_agent::pb;
use harmont_agent::pb::agent_frame::Payload as Up;
use harmont_agent::pb::server_frame::Payload as Down;
use harmont_agent::{child, signals, source, spool, ws};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::watch;

const PROTO_VERSION: u32 = 1;
const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");

enum SessionOutcome {
    Terminal,
    Reconnect,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("harmont_agent=info".parse().unwrap()),
        )
        .init();

    let cfg = AgentConfig::parse();
    let code = match run(cfg).await {
        Ok(()) => 0,
        Err(e) => {
            tracing::error!(error = %e, "agent exiting with error");
            exit_code_for(&e)
        }
    };
    std::process::exit(code);
}

async fn run(cfg: AgentConfig) -> Result<(), AgentError> {
    // Resolve the runner token once (file preferred over inline) so the secret
    // never has to be re-read and stays out of argv/env logging downstream.
    let token = cfg.resolve_token()?;
    let mut spool = spool::Spool::open_with_cap(&cfg.spool_dir, cfg.max_spool_bytes)?;
    let instance_id = uuid::Uuid::new_v4().to_string();
    tracing::info!(instance_id, "agent run start");

    // First-session setup is deferred until we have a JobSpec.
    // The outer loop owns these so they persist across reconnects.
    let mut child: Option<child::ChildHandle> = None;
    let mut cached_spec: Option<pb::JobSpec> = None;
    let (cancel_tx, _cancel_rx_handle) = tokio::sync::watch::channel(false);
    let (timeout_tx, _timeout_rx_handle) = tokio::sync::watch::channel(false);
    let mut timeout_armed = false;

    let mut last_successful = std::time::Instant::now();
    let mut backoff = ws::backoff_schedule();

    loop {
        let client = ws::WsClient {
            api_url: cfg.api_url.clone(),
            token: token.clone(),
        };
        let stream = match client.connect().await {
            Ok(s) => {
                last_successful = std::time::Instant::now();
                backoff = ws::backoff_schedule();
                s
            }
            Err(e) => {
                tracing::warn!(error = %e, "connect failed; backing off");
                if last_successful.elapsed()
                    > std::time::Duration::from_secs(cfg.abort_after_disconnect_sec)
                {
                    if let Some(mut c) = child.take() {
                        let _ = nix::sys::signal::kill(
                            nix::unistd::Pid::from_raw(-c.pgid),
                            nix::sys::signal::Signal::SIGTERM,
                        );
                        let _ = c.child.wait().await;
                    }
                    return Err(AgentError::Protocol(
                        "abort: disconnected too long".into(),
                    ));
                }
                if let Some(d) = backoff.next() {
                    tokio::time::sleep(d).await;
                }
                continue;
            }
        };

        match run_session(
            &cfg,
            &token,
            &instance_id,
            &mut spool,
            stream,
            &mut cached_spec,
            &mut child,
            &cancel_tx,
            &timeout_tx,
            &mut timeout_armed,
        )
        .await
        {
            Ok(SessionOutcome::Terminal) => return Ok(()),
            Ok(SessionOutcome::Reconnect) => {
                tracing::info!("session ended without terminal; reconnecting");
                if last_successful.elapsed()
                    > std::time::Duration::from_secs(cfg.abort_after_disconnect_sec)
                {
                    if let Some(mut c) = child.take() {
                        let _ = nix::sys::signal::kill(
                            nix::unistd::Pid::from_raw(-c.pgid),
                            nix::sys::signal::Signal::SIGTERM,
                        );
                        let _ = c.child.wait().await;
                    }
                    return Err(AgentError::Protocol(
                        "abort: disconnected too long".into(),
                    ));
                }
            }
            Err(e) => {
                tracing::warn!(error = %e, "session error; reconnecting");
                if last_successful.elapsed()
                    > std::time::Duration::from_secs(cfg.abort_after_disconnect_sec)
                {
                    if let Some(mut c) = child.take() {
                        let _ = nix::sys::signal::kill(
                            nix::unistd::Pid::from_raw(-c.pgid),
                            nix::sys::signal::Signal::SIGTERM,
                        );
                        let _ = c.child.wait().await;
                    }
                    return Err(e);
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_session(
    cfg: &AgentConfig,
    token: &str,
    instance_id: &str,
    spool: &mut spool::Spool,
    mut stream: ws::StreamHandles,
    cached_spec: &mut Option<pb::JobSpec>,
    child_slot: &mut Option<child::ChildHandle>,
    cancel_tx: &watch::Sender<bool>,
    timeout_tx: &watch::Sender<bool>,
    timeout_armed: &mut bool,
) -> Result<SessionOutcome, AgentError> {
    // Hello.
    let last_acked = spool.acked_seq();
    stream
        .tx
        .send(pb::AgentFrame {
            payload: Some(Up::Hello(pb::HelloMsg {
                instance_id: instance_id.to_owned(),
                agent_version: AGENT_VERSION.into(),
                proto_version: PROTO_VERSION,
                build_id: cfg.build_id.clone(),
                job_id: cfg.job_id.clone(),
                last_acked_seq: last_acked,
            })),
        })
        .await
        .map_err(|_| AgentError::Protocol("tx closed before Hello".into()))?;

    // Expect ResumeInfo then optionally JobSpec.
    let resume = expect_frame(&mut stream.rx).await?;
    let resume = match resume.payload {
        Some(Down::Resume(r)) => r,
        other => {
            return Err(AgentError::Protocol(format!(
                "expected ResumeInfo, got {other:?}"
            )));
        }
    };

    // Replay unacked chunks, skipping any the server already has.
    let resume_floor = std::cmp::max(spool.acked_seq(), resume.server_max_seq);
    let unacked: Vec<_> = spool
        .iter_from(resume_floor)?
        .collect::<Result<_, _>>()?;
    for chunk in unacked {
        if stream
            .tx
            .send(pb::AgentFrame {
                payload: Some(Up::Log(chunk)),
            })
            .await
            .is_err()
        {
            return Ok(SessionOutcome::Reconnect);
        }
    }

    let spec = if resume.spec_already_sent {
        match cached_spec.clone() {
            Some(s) => s,
            None => {
                return Err(AgentError::Protocol(
                    "server says spec already sent but agent has no cached spec".into(),
                ));
            }
        }
    } else {
        let f = expect_frame(&mut stream.rx).await?;
        let s = match f.payload {
            Some(Down::Spec(s)) => s,
            other => {
                return Err(AgentError::Protocol(format!(
                    "expected JobSpec, got {other:?}"
                )));
            }
        };
        *cached_spec = Some(s.clone());
        s
    };

    // Spawn child ONLY on the first session. Subsequent sessions reuse the
    // still-running child to avoid double-execution across WS reconnects.
    if child_slot.is_none() {
        let workspace = PathBuf::from("/workspace");
        source::fetch_and_extract(&spec.source_url, &spec.source_sha256, &workspace, token)
            .await?;

        let env: HashMap<String, String> = spec
            .env
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let new_child = child::spawn(child::SpawnRequest {
            command: spec.command.clone(),
            env,
            cwd: workspace.clone(),
        })
        .await?;
        *child_slot = Some(new_child);
    }

    // Announce state transitions on EVERY session — including reconnects.
    // If the first session's child was spawned but the JobAssignedToSandbox
    // or JobStarted send failed before the WS dropped, the server's engine
    // never observed the transition; re-sending here recovers it. Duplicates
    // are dropped harmlessly by the engine as illegal-transition breadcrumbs
    // (see Worker.Transition).
    send_state(
        &mut stream.tx,
        pb::state_msg::Transition::JobAssignedToSandbox,
        None,
        None,
        None,
    )
    .await?;
    send_state(
        &mut stream.tx,
        pb::state_msg::Transition::JobStarted,
        None,
        None,
        None,
    )
    .await?;

    // Arm the timeout timer once across the agent's lifetime, regardless
    // of how many reconnects happen. The flag prevents double-arming.
    if !*timeout_armed && spec.timeout_sec > 0 {
        *timeout_armed = true;
        let tx = timeout_tx.clone();
        let dur = Duration::from_secs(u64::from(spec.timeout_sec));
        tokio::spawn(async move {
            tokio::time::sleep(dur).await;
            let _ = tx.send(true);
        });
    }

    let child = child_slot.as_mut().expect("child must be set after first session");

    // Subscribe receivers from the shared watch channels.
    let cancel_rx = cancel_tx.subscribe();
    let timeout_rx = timeout_tx.subscribe();

    // Watch channel to receive ack seq numbers from the server_rx side task.
    let (ack_tx, mut ack_rx) = tokio::sync::watch::channel::<u64>(0);

    // Forward incoming ServerFrames (cancel, ack) on a side task.
    let cancel_tx2 = cancel_tx.clone();
    let mut server_rx = stream.rx;
    let _server_task = tokio::spawn(async move {
        while let Some(frame) = server_rx.recv().await {
            match frame.payload {
                Some(Down::Cancel(_)) => {
                    let _ = cancel_tx2.send(true);
                }
                Some(Down::Ack(a)) => {
                    let _ = ack_tx.send(a.range_end);
                }
                Some(Down::Error(e)) => {
                    tracing::error!(?e, "server error frame");
                    let _ = cancel_tx2.send(true);
                }
                _ => {}
            }
        }
    });

    // Stream log lines.
    let mut next_seq: u64 = std::cmp::max(spool.max_persisted_seq()?, last_acked) + 1;
    let mut heartbeat_tick =
        tokio::time::interval(Duration::from_secs(cfg.heartbeat_interval_sec));
    heartbeat_tick.tick().await; // skip first immediate tick

    let outcome: Option<signals::TerminationReason> = loop {
        tokio::select! {
            Some(line) = child.stdout_lines.recv() => {
                let chunk = make_chunk(next_seq, pb::log_chunk::Stream::Stdout, line.bytes);
                spool.append(&chunk)?;
                if stream.tx.send(pb::AgentFrame { payload: Some(Up::Log(chunk)) }).await.is_err() {
                    return Ok(SessionOutcome::Reconnect);
                }
                next_seq += 1;
            }
            Some(line) = child.stderr_lines.recv() => {
                let chunk = make_chunk(next_seq, pb::log_chunk::Stream::Stderr, line.bytes);
                spool.append(&chunk)?;
                if stream.tx.send(pb::AgentFrame { payload: Some(Up::Log(chunk)) }).await.is_err() {
                    return Ok(SessionOutcome::Reconnect);
                }
                next_seq += 1;
            }
            _ = heartbeat_tick.tick() => {
                let now_ns = now_ns();
                let _ = stream.tx.send(pb::AgentFrame {
                    payload: Some(Up::Heartbeat(pb::Heartbeat { ts_unix_ns: now_ns })),
                }).await;
            }
            status = child.child.wait() => {
                // Child exited naturally; status consumed here.
                let _ = status;
                break None;
            }
            _ = wait_watch(cancel_rx.clone()) => {
                break Some(signals::TerminationReason::Cancel);
            }
            _ = wait_watch(timeout_rx.clone()) => {
                break Some(signals::TerminationReason::Timeout);
            }
            Ok(()) = ack_rx.changed() => {
                let seq = *ack_rx.borrow();
                if seq > 0 {
                    if let Err(e) = spool.set_acked_seq(seq) {
                        tracing::warn!(error = %e, "ack persist failed");
                    }
                    if let Err(e) = spool.maybe_rotate() {
                        tracing::warn!(error = %e, "spool rotate failed");
                    }
                }
            }
        }
    };

    // If cancelled/timed-out, enforce SIGTERM → grace → SIGKILL.
    if outcome.is_some() {
        let sup = signals::Supervisor {
            cancel_rx: cancel_rx.clone(),
            timeout_rx: timeout_rx.clone(),
            grace: Duration::from_secs(u64::from(spec.grace_sec.max(1))),
        };
        let _ = sup.enforce(child).await;
    }

    // Drain any remaining lines before reading final exit status.
    drain_remaining_lines(child, spool, &mut stream.tx, &mut next_seq).await?;

    // Determine terminal transition.
    let status = child.child.wait().await.ok();
    let transition = match (outcome, status) {
        (Some(signals::TerminationReason::Timeout), _) => {
            pb::state_msg::Transition::JobTimeoutExpired
        }
        (Some(signals::TerminationReason::Cancel), _) => {
            pb::state_msg::Transition::JobReportedFailed
        }
        (None, Some(ref s)) if s.success() => pb::state_msg::Transition::JobReportedPassed,
        (None, Some(ref s)) => {
            let code = s.code();
            let sig = std::os::unix::process::ExitStatusExt::signal(s);
            send_state(
                &mut stream.tx,
                pb::state_msg::Transition::JobReportedFailed,
                code,
                sig,
                None,
            )
            .await?;
            send_bye(&mut stream.tx).await;
            return Ok(SessionOutcome::Terminal);
        }
        _ => pb::state_msg::Transition::JobReportedFailed,
    };
    send_state(&mut stream.tx, transition, None, None, None).await?;

    send_bye(&mut stream.tx).await;
    Ok(SessionOutcome::Terminal)
}

fn now_ns() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as i64
}

fn make_chunk(seq: u64, stream: pb::log_chunk::Stream, data: Vec<u8>) -> pb::LogChunk {
    pb::LogChunk {
        seq,
        ts_unix_ns: now_ns(),
        stream: stream as i32,
        data,
    }
}

async fn send_state(
    tx: &mut tokio::sync::mpsc::Sender<pb::AgentFrame>,
    transition: pb::state_msg::Transition,
    exit_code: Option<i32>,
    signal: Option<i32>,
    detail: Option<String>,
) -> Result<(), AgentError> {
    tx.send(pb::AgentFrame {
        payload: Some(Up::State(pb::StateMsg {
            transition: transition as i32,
            exit_code,
            signal,
            detail,
        })),
    })
    .await
    .map_err(|_| AgentError::Protocol("tx closed".into()))?;
    Ok(())
}

async fn send_bye(tx: &mut tokio::sync::mpsc::Sender<pb::AgentFrame>) {
    let _ = tx
        .send(pb::AgentFrame {
            payload: Some(Up::Bye(pb::ByeMsg {
                reason: pb::bye_msg::Reason::CleanExit as i32,
                detail: String::new(),
            })),
        })
        .await;
}

async fn wait_watch(mut rx: watch::Receiver<bool>) {
    loop {
        if *rx.borrow() {
            return;
        }
        if rx.changed().await.is_err() {
            return;
        }
    }
}

async fn expect_frame(
    rx: &mut tokio::sync::mpsc::Receiver<pb::ServerFrame>,
) -> Result<pb::ServerFrame, AgentError> {
    rx.recv()
        .await
        .ok_or_else(|| AgentError::Protocol("server closed stream early".into()))
}

async fn drain_remaining_lines(
    child: &mut child::ChildHandle,
    spool: &mut spool::Spool,
    tx: &mut tokio::sync::mpsc::Sender<pb::AgentFrame>,
    next_seq: &mut u64,
) -> Result<(), AgentError> {
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        tokio::select! {
            biased;
            Some(line) = child.stdout_lines.recv() => {
                let c = make_chunk(*next_seq, pb::log_chunk::Stream::Stdout, line.bytes);
                spool.append(&c)?;
                let _ = tx.send(pb::AgentFrame { payload: Some(Up::Log(c)) }).await;
                *next_seq += 1;
            }
            Some(line) = child.stderr_lines.recv() => {
                let c = make_chunk(*next_seq, pb::log_chunk::Stream::Stderr, line.bytes);
                spool.append(&c)?;
                let _ = tx.send(pb::AgentFrame { payload: Some(Up::Log(c)) }).await;
                *next_seq += 1;
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => { break; }
            else => break,
        }
    }
    Ok(())
}
