//! The high-level Harmont Cloud client.

use harmont_cloud_raw::Client as RawClient;
use crate::{HarmontError, Result};

/// Default production API base URL.
pub const DEFAULT_BASE_URL: &str = "https://api.harmont.dev";

/// A configured client for the Harmont Cloud API.
///
/// Construct with [`HarmontClient::new`] (prod) or
/// [`HarmontClient::with_base_url`] (self-hosted / local dev). The bearer
/// token is attached to every request via a preconfigured [`reqwest::Client`].
#[derive(Clone, Debug)]
pub struct HarmontClient {
    pub(crate) raw: RawClient,
    pub(crate) http: reqwest::Client,
    pub(crate) base: String,
}

impl HarmontClient {
    /// Create a client against the production API.
    pub fn new(token: impl Into<String>) -> Self {
        Self::with_base_url(token, DEFAULT_BASE_URL)
    }

    /// Create a client against an explicit base URL.
    ///
    /// # Panics
    ///
    /// Panics if `token` contains characters that are invalid for an HTTP
    /// header value (e.g. non-ASCII or control characters).
    pub fn with_base_url(token: impl Into<String>, base: impl Into<String>) -> Self {
        let token = token.into();
        let base = base.into();
        let mut headers = reqwest::header::HeaderMap::new();
        let mut auth = reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))
            .expect("API token contains characters invalid for an HTTP Authorization header");
        auth.set_sensitive(true); // keep the token out of any header debug output
        headers.insert(reqwest::header::AUTHORIZATION, auth);
        let http = reqwest::Client::builder()
            .default_headers(headers)
            .build()
            .expect("reqwest client builds with static config");
        let raw = RawClient::new_with_client(&base, http.clone());
        Self { raw, http, base }
    }

    /// Create a client with no credentials, for anonymous endpoints
    /// (the CLI auth flows: redeem/claim). Sends no Authorization header.
    pub fn anonymous(base: impl Into<String>) -> Self {
        let base = base.into();
        let http = reqwest::Client::builder()
            .build()
            .expect("reqwest client builds with static config");
        let raw = RawClient::new_with_client(&base, http.clone());
        Self { raw, http, base }
    }

    /// The configured base URL.
    pub fn base_url(&self) -> &str {
        &self.base
    }

    /// The raw generated client, for endpoints the high-level API does not wrap.
    pub fn raw(&self) -> &RawClient {
        &self.raw
    }

    /// Decode a response, mapping non-2xx to a structured [`HarmontError`].
    pub(crate) async fn parse_json<T: serde::de::DeserializeOwned>(
        &self, resp: reqwest::Response,
    ) -> Result<T> {
        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(HarmontError::Unauthorized);
        }
        let bytes = resp.bytes().await?;
        if status.is_success() {
            return serde_json::from_slice(&bytes).map_err(|e| HarmontError::Decode(e.to_string()));
        }
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(HarmontError::NotFound(String::from_utf8_lossy(&bytes).into()));
        }
        let (code, message) = parse_error_body(&bytes);
        Err(HarmontError::Api { status: status.as_u16(), code, message })
    }

    /// Like [`Self::parse_json`], but maps a 404 through the structured error
    /// body too (rather than the opaque `NotFound(raw_body)` path). Use for
    /// endpoints whose 404 carries a meaningful `code`/`message` worth
    /// surfacing verbatim — e.g. create-by-source's "pipeline not found".
    pub(crate) async fn parse_json_structured<T: serde::de::DeserializeOwned>(
        &self,
        resp: reqwest::Response,
    ) -> Result<T> {
        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(HarmontError::Unauthorized);
        }
        let bytes = resp.bytes().await?;
        if status.is_success() {
            return serde_json::from_slice(&bytes).map_err(|e| HarmontError::Decode(e.to_string()));
        }
        let (code, message) = parse_error_body(&bytes);
        Err(HarmontError::Api { status: status.as_u16(), code, message })
    }
}

fn parse_error_body(bytes: &[u8]) -> (String, String) {
    let v: serde_json::Value = serde_json::from_slice(bytes).unwrap_or(serde_json::Value::Null);
    let obj = v.get("error").unwrap_or(&v);
    let code = obj.get("code").and_then(|c| c.as_str()).unwrap_or("unknown").to_string();
    let message = obj.get("message").and_then(|m| m.as_str())
        .unwrap_or_else(|| std::str::from_utf8(bytes).unwrap_or("")).to_string();
    (code, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_base_url_is_prod() {
        let c = HarmontClient::new("hm_test");
        assert_eq!(c.base_url(), "https://api.harmont.dev");
    }

    #[test]
    fn custom_base_url_is_used() {
        let c = HarmontClient::with_base_url("hm_test", "http://localhost:4000");
        assert_eq!(c.base_url(), "http://localhost:4000");
    }
}
