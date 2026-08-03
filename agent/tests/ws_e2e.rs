//! End-to-end: spin up an in-process WebSocket server, run the agent binary
//! as a tokio task pointed at it, drive a fake build through, assert frames.

use futures_util::{SinkExt, StreamExt};
use harmont_agent::pb;
use prost::Message;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message as WsMsg;

#[tokio::test]
async fn agent_reports_source_failure_terminally() {
    // Bad source_url drives the agent to fail at source fetch and report
    // JOB_SANDBOX_LOST. Exercises Hello → Resume → Spec → terminal path.

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let frames: Arc<Mutex<Vec<pb::AgentFrame>>> = Default::default();
    let frames2 = frames.clone();

    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        // Read Hello.
        if let Some(Ok(WsMsg::Binary(bytes))) = ws.next().await {
            let frame = pb::AgentFrame::decode(&bytes[..]).unwrap();
            frames2.lock().await.push(frame);
        }

        // Send ResumeInfo + JobSpec.
        let resume = pb::ServerFrame {
            payload: Some(pb::server_frame::Payload::Resume(pb::ResumeInfo {
                server_max_seq: 0,
                spec_already_sent: false,
            })),
        };
        ws.send(WsMsg::Binary(resume.encode_to_vec()))
            .await
            .unwrap();

        let spec = pb::ServerFrame {
            payload: Some(pb::server_frame::Payload::Spec(pb::JobSpec {
                command: "echo hello".into(),
                env: Default::default(),
                timeout_sec: 60,
                source_url: "http://127.0.0.1:1/none.tar.gz".into(),
                source_sha256: "0".repeat(64),
                grace_sec: 5,
                max_log_bytes: 0,
            })),
        };
        ws.send(WsMsg::Binary(spec.encode_to_vec()))
            .await
            .unwrap();

        while let Some(Ok(msg)) = ws.next().await {
            if let WsMsg::Binary(bytes) = msg
                && let Ok(f) = pb::AgentFrame::decode(&bytes[..])
            {
                frames2.lock().await.push(f);
            }
        }
    });

    let agent_bin = env!("CARGO_BIN_EXE_harmont-agent");
    let spool = tempfile::tempdir().unwrap();
    let output = tokio::process::Command::new(agent_bin)
        .env("HARMONT_BUILD_ID", "b1")
        .env("HARMONT_JOB_ID", "j1")
        .env("HARMONT_API_URL", format!("http://{}", addr))
        .env("HARMONT_TOKEN", "tok")
        .env("HARMONT_AGENT_SPOOL_DIR", spool.path())
        .env("HARMONT_AGENT_ABORT_DISCO_SEC", "5")
        .kill_on_drop(true)
        .output()
        .await
        .unwrap();

    assert!(!output.status.success(), "agent exited zero unexpectedly");

    let frames = frames.lock().await;
    assert!(
        matches!(
            frames.first().and_then(|f| f.payload.as_ref()),
            Some(pb::agent_frame::Payload::Hello(_))
        ),
        "first frame must be Hello, got {:?}",
        frames.first()
    );
}
