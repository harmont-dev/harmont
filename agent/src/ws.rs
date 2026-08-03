//! WebSocket client for the agent. Owns a single duplex connection to
//! /v0/agent/connect with reconnect-with-backoff handled by the caller.
//! Each WS binary frame carries exactly one encoded AgentFrame (up) or
//! ServerFrame (down).

use crate::error::AgentError;
use crate::pb;
use futures_util::{SinkExt, StreamExt};
use http::header::AUTHORIZATION;
use prost::Message;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::Message as WsMsg;

pub struct WsClient {
    pub api_url: String,
    pub token: String,
}

pub struct StreamHandles {
    pub tx: mpsc::Sender<pb::AgentFrame>,
    pub rx: mpsc::Receiver<pb::ServerFrame>,
}

impl WsClient {
    pub async fn connect(&self) -> Result<StreamHandles, AgentError> {
        let upgrade_url = {
            let mut u = url::Url::parse(&self.api_url)
                .map_err(|e| AgentError::Protocol(format!("bad api_url: {e}")))?;
            let scheme = match u.scheme() {
                "http"  => "ws",
                "https" => "wss",
                s => return Err(AgentError::Protocol(format!("unsupported scheme {s}"))),
            };
            u.set_scheme(scheme).map_err(|_| AgentError::Protocol("set_scheme".into()))?;
            u.set_path("/v0/agent/connect");
            u
        };

        let mut req = upgrade_url.as_str().into_client_request()
            .map_err(|e| AgentError::Protocol(format!("client_request: {e}")))?;
        let bearer = format!("Bearer {}", self.token);
        req.headers_mut().insert(
            AUTHORIZATION,
            bearer.parse().map_err(|e| AgentError::Protocol(format!("token: {e}")))?,
        );

        let (ws, _resp) = tokio_tungstenite::connect_async(req).await
            .map_err(|e| AgentError::Protocol(format!("ws connect: {e}")))?;

        let (mut sink, mut stream) = ws.split();

        let (tx, mut tx_rx) = mpsc::channel::<pb::AgentFrame>(64);
        let (rx_tx, rx) = mpsc::channel::<pb::ServerFrame>(64);

        // Outbound: drain tx_rx → encode → WS binary frame.
        tokio::spawn(async move {
            while let Some(frame) = tx_rx.recv().await {
                let mut buf = Vec::with_capacity(frame.encoded_len());
                if frame.encode(&mut buf).is_err() {
                    return;
                }
                if sink.send(WsMsg::Binary(buf)).await.is_err() {
                    return;
                }
            }
            let _ = sink.send(WsMsg::Close(None)).await;
        });

        // Inbound: read WS frames → decode → push to rx_tx.
        tokio::spawn(async move {
            while let Some(msg) = stream.next().await {
                let msg = match msg {
                    Ok(m) => m,
                    Err(_) => return,
                };
                match msg {
                    WsMsg::Binary(bytes) => {
                        if let Ok(f) = pb::ServerFrame::decode(&bytes[..])
                            && rx_tx.send(f).await.is_err()
                        {
                            return;
                        }
                    }
                    WsMsg::Ping(_) | WsMsg::Pong(_) => { /* tungstenite handles auto-pong */ }
                    WsMsg::Close(_) => return,
                    _ => { /* text frames are protocol violation; ignore */ }
                }
            }
        });

        Ok(StreamHandles { tx, rx })
    }
}

// Used by the reconnect loop added in a later task.
#[allow(dead_code)]
pub fn backoff_schedule() -> impl Iterator<Item = Duration> {
    let secs = [1u64, 2, 4, 8, 16, 32];
    secs.into_iter()
        .map(Duration::from_secs)
        .chain(std::iter::repeat(Duration::from_secs(60)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_starts_at_one_second_and_caps_at_sixty() {
        let mut it = backoff_schedule();
        assert_eq!(it.next(), Some(Duration::from_secs(1)));
        assert_eq!(it.next(), Some(Duration::from_secs(2)));
        let nth = it.nth(20).unwrap();
        assert_eq!(nth, Duration::from_secs(60));
    }
}
