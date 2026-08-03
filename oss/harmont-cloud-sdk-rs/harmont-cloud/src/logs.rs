//! Live job log streaming over SSE.
//!
//! The log stream is **not** part of the OpenAPI spec, so it is hand-written
//! here. Flow: mint a build-scoped token via [`HarmontClient::log_token`],
//! then [`HarmontClient::stream_job_logs`] yields [`LogEvent`]s per job until
//! the terminal `done` event.

use futures_core::Stream;
use futures_util::StreamExt;
use eventsource_stream::Eventsource;
use uuid::Uuid;
use crate::{HarmontClient, HarmontError, Result};

/// stdout / stderr / meta, per the server's `stream_kind` (0/1/2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamKind { Stdout, Stderr, Meta }

impl StreamKind {
    fn from_i64(n: i64) -> Self {
        match n { 1 => StreamKind::Stderr, 2 => StreamKind::Meta, _ => StreamKind::Stdout }
    }
}

/// One log chunk. `content` may hold multiple lines or a partial line —
/// callers buffer and split on `\n` themselves.
#[derive(Debug, Clone)]
pub struct LogChunk {
    pub seq: i64,
    pub stream: StreamKind,
    pub content: String,
    pub ts_unix_ns: Option<i64>,
}

/// A decoded SSE event from the job log stream.
#[derive(Debug, Clone)]
pub enum LogEvent {
    /// Replay of prior chunks, sent once on connect.
    History(Vec<LogChunk>),
    /// A live chunk.
    Chunk(LogChunk),
    /// Terminal: the job reached a terminal state; the stream is finished.
    Done,
}

#[derive(serde::Deserialize)]
struct RawChunk { seq: i64, stream_kind: i64, content: String, ts: Option<i64> }

impl From<RawChunk> for LogChunk {
    fn from(r: RawChunk) -> Self {
        LogChunk { seq: r.seq, stream: StreamKind::from_i64(r.stream_kind),
                   content: r.content, ts_unix_ns: r.ts }
    }
}

/// Decode one SSE (event, data) pair. Returns `Ok(None)` for ignored events.
pub(crate) fn decode_event(event: &str, data: &str) -> Result<Option<LogEvent>> {
    match event {
        "chunk" => {
            let r: RawChunk = serde_json::from_str(data)
                .map_err(|e| HarmontError::LogStream(e.to_string()))?;
            Ok(Some(LogEvent::Chunk(r.into())))
        }
        "history" => {
            #[derive(serde::Deserialize)]
            struct H { chunks: Vec<RawChunk> }
            let h: H = serde_json::from_str(data)
                .map_err(|e| HarmontError::LogStream(e.to_string()))?;
            Ok(Some(LogEvent::History(h.chunks.into_iter().map(Into::into).collect())))
        }
        "done" => Ok(Some(LogEvent::Done)),
        _ => Ok(None),
    }
}

/// A minted, build-scoped log token.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct LogToken {
    pub token: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

impl HarmontClient {
    /// Mint a build-scoped HMAC log token (authorizes every job in the build).
    pub async fn log_token(&self, org: &str, pipeline: &str, number: i64) -> Result<LogToken> {
        let url = format!(
            "{}/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/log-token",
            self.base
        );
        let resp = self.http.get(&url).send().await?;
        self.parse_json(resp).await
    }

    /// Stream a single job's logs until the `done` event. `log_base` is the
    /// host serving `/v0/jobs/{id}/logs` (the web edge, e.g. the API base);
    /// `token` comes from [`Self::log_token`].
    pub async fn stream_job_logs(
        &self, log_base: &str, job_id: Uuid, token: &str,
    ) -> Result<impl Stream<Item = Result<LogEvent>>> {
        let url = format!("{log_base}/v0/jobs/{job_id}/logs?token={token}");
        let resp = self.http
            .get(&url)
            .header(reqwest::header::ACCEPT, "text/event-stream")
            .send()
            .await?;
        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            return Err(HarmontError::Unauthorized);
        }
        if !resp.status().is_success() {
            return Err(HarmontError::LogStream(format!("status {}", resp.status())));
        }
        let stream = resp.bytes_stream().eventsource().filter_map(|item| async move {
            match item {
                Ok(ev) => decode_event(&ev.event, &ev.data).transpose(),
                Err(e) => Some(Err(HarmontError::LogStream(e.to_string()))),
            }
        });
        Ok(stream)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_chunk_event() {
        let data = r#"{"seq":7,"stream_kind":1,"content":"boom\n","ts":1234}"#;
        let ev = decode_event("chunk", data).expect("some").expect("ok");
        match ev {
            LogEvent::Chunk(c) => {
                assert_eq!(c.seq, 7);
                assert_eq!(c.stream, StreamKind::Stderr);
                assert_eq!(c.content, "boom\n");
                assert_eq!(c.ts_unix_ns, Some(1234));
            }
            _ => panic!("expected chunk"),
        }
    }

    #[test]
    fn decodes_done_event() {
        let ev = decode_event("done", "{}").expect("some").expect("ok");
        assert!(matches!(ev, LogEvent::Done));
    }

    #[test]
    fn ignores_unknown_event() {
        assert!(decode_event("comment", "irrelevant").expect("ok").is_none());
    }

    #[test]
    fn decodes_history_batch() {
        let data = r#"{"chunks":[{"seq":0,"stream_kind":0,"content":"hi","ts":null}]}"#;
        let ev = decode_event("history", data).expect("some").expect("ok");
        match ev { LogEvent::History(v) => assert_eq!(v.len(), 1), _ => panic!("expected history") }
    }
}
