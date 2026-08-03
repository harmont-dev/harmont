//! Error type for the Harmont Cloud SDK.

/// Errors surfaced by [`crate::HarmontClient`].
#[derive(Debug, thiserror::Error)]
pub enum HarmontError {
    /// The request was not authenticated (no/invalid/expired token).
    #[error("unauthorized — run `hm login` or set HARMONT_API_TOKEN")]
    Unauthorized,

    /// The API returned a non-2xx status with a structured error body.
    #[error("api error {status} [{code}]: {message}")]
    Api { status: u16, code: String, message: String },

    /// Transport/connection failure.
    #[error("network error: {0}")]
    Transport(String),

    /// Response body could not be decoded.
    #[error("decode error: {0}")]
    Decode(String),

    /// SSE log stream framing error.
    #[error("log stream error: {0}")]
    LogStream(String),

    /// The requested resource was not found (404).
    #[error("not found: {0}")]
    NotFound(String),
}

impl From<reqwest::Error> for HarmontError {
    fn from(e: reqwest::Error) -> Self {
        if e.is_decode() { HarmontError::Decode(e.to_string()) }
        else { HarmontError::Transport(e.to_string()) }
    }
}

pub type Result<T> = std::result::Result<T, HarmontError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_error_carries_status_and_code() {
        let e = HarmontError::Api { status: 422, code: "build_rejected".into(),
                                    message: "pipeline_ir invalid".into() };
        let s = e.to_string();
        assert!(s.contains("422"));
        assert!(s.contains("build_rejected"));
        assert!(s.contains("pipeline_ir invalid"));
    }

    #[test]
    fn unauthorized_is_distinguishable() {
        let e = HarmontError::Unauthorized;
        assert!(matches!(e, HarmontError::Unauthorized));
    }
}
