//! CLI authentication flows.
//!
//! Two paths produce a bearer token: paste-code (headless/SSH) and loopback
//! (browser on the same machine). Both are anonymous endpoints; construct the
//! client with an empty token for these calls. `create_api_token` requires an
//! already-authenticated client.

use crate::{HarmontClient, Result};

impl HarmontClient {
    /// Redeem a paste code for a bearer token (headless login).
    ///
    /// The user obtains the paste code from the SPA (which calls the authed
    /// `GET /api/v0/auth/cli/code` endpoint while logged in) and types it into
    /// the CLI. Single-use, expires in 5 minutes.
    pub async fn redeem_code(&self, code: &str) -> Result<String> {
        let url = format!("{}/api/v0/auth/cli/redeem", self.base);
        let resp = self.http.post(&url)
            .json(&serde_json::json!({ "code": code }))
            .send().await?;
        #[derive(serde::Deserialize)]
        struct R { token: String }
        let r: R = self.parse_json(resp).await?;
        Ok(r.token)
    }

    /// Claim a loopback-parked token by nonce (browser login).
    ///
    /// The CLI generates a random nonce, opens the browser to the SPA, and
    /// polls this endpoint until the token appears (the SPA calls the authed
    /// `POST /api/v0/auth/cli/transfer` endpoint). Single-use, expires in 60
    /// seconds. Callers should retry on [`crate::HarmontError::Api`] with code
    /// `cli_code_invalid` until the token is claimed or the window closes.
    pub async fn claim_token(&self, nonce: &str) -> Result<String> {
        let url = format!("{}/api/v0/auth/cli/claim", self.base);
        let resp = self.http.post(&url)
            .json(&serde_json::json!({ "nonce": nonce }))
            .send().await?;
        #[derive(serde::Deserialize)]
        struct R { token: String }
        let r: R = self.parse_json(resp).await?;
        Ok(r.token)
    }

    /// Mint a personal API token (requires an authenticated client).
    ///
    /// The raw token is returned once and never retrievable again. Store it
    /// securely (e.g. in the system keychain or `~/.config/harmont/token`).
    pub async fn create_api_token(&self, description: &str) -> Result<String> {
        let url = format!("{}/api/v0/user/api-tokens", self.base);
        let resp = self.http.post(&url)
            .json(&serde_json::json!({ "description": description }))
            .send().await?;
        #[derive(serde::Deserialize)]
        struct R { token: String }
        let r: R = self.parse_json(resp).await?;
        Ok(r.token)
    }
}

#[cfg(test)]
mod tests {
    use crate::HarmontClient;
    use wiremock::matchers::{body_partial_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};
    use serde_json::json;

    #[tokio::test]
    async fn redeem_returns_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/redeem"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "hm_live"})))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        let tok = client.redeem_code("ABCD-1234").await.expect("ok");
        assert_eq!(tok, "hm_live");
    }

    #[tokio::test]
    async fn redeem_sends_code_field() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/redeem"))
            .and(body_partial_json(json!({"code": "ZZZZ-9999"})))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "hm_abc"})))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        client.redeem_code("ZZZZ-9999").await.expect("ok");
    }

    #[tokio::test]
    async fn redeem_invalid_code_maps_to_api_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/redeem"))
            .respond_with(ResponseTemplate::new(400).set_body_json(json!({
                "error": {"code": "cli_code_invalid", "message": "This CLI code is invalid, expired, or already used."}
            })))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        let err = client.redeem_code("BAD-CODE").await.unwrap_err();
        match err {
            crate::HarmontError::Api { status, code, .. } => {
                assert_eq!(status, 400);
                assert_eq!(code, "cli_code_invalid");
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn claim_returns_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/claim"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "hm_session"})))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        let tok = client.claim_token("my-random-nonce-xyz").await.expect("ok");
        assert_eq!(tok, "hm_session");
    }

    #[tokio::test]
    async fn claim_sends_nonce_field() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/claim"))
            .and(body_partial_json(json!({"nonce": "abc-nonce-123"})))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "hm_tok"})))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        client.claim_token("abc-nonce-123").await.expect("ok");
    }

    #[tokio::test]
    async fn claim_not_yet_available_maps_to_api_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/auth/cli/claim"))
            .respond_with(ResponseTemplate::new(400).set_body_json(json!({
                "error": {"code": "cli_code_invalid", "message": "No token parked for this nonce yet."}
            })))
            .mount(&server).await;
        let client = HarmontClient::anonymous(server.uri());
        let err = client.claim_token("no-match-nonce").await.unwrap_err();
        match err {
            crate::HarmontError::Api { status, code, .. } => {
                assert_eq!(status, 400);
                assert_eq!(code, "cli_code_invalid");
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn create_api_token_returns_raw_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/user/api-tokens"))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({
                "token": "hm_personal_abc123",
                "api_token": {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "description": "my local machine",
                    "created_at": "2026-06-04T00:00:00Z",
                    "expires_at": null,
                    "last_used_at": null
                }
            })))
            .mount(&server).await;
        let client = HarmontClient::with_base_url("hm_session_token", server.uri());
        let raw = client.create_api_token("my local machine").await.expect("ok");
        assert_eq!(raw, "hm_personal_abc123");
    }

    #[tokio::test]
    async fn create_api_token_sends_description_field() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/user/api-tokens"))
            .and(body_partial_json(json!({"description": "laptop key"})))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({
                "token": "hm_xyz",
                "api_token": {
                    "id": "00000000-0000-0000-0000-000000000002",
                    "description": "laptop key",
                    "created_at": "2026-06-04T00:00:00Z",
                    "expires_at": null,
                    "last_used_at": null
                }
            })))
            .mount(&server).await;
        let client = HarmontClient::with_base_url("hm_session", server.uri());
        client.create_api_token("laptop key").await.expect("ok");
    }

    #[tokio::test]
    async fn create_api_token_unauthorized_maps_cleanly() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/user/api-tokens"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server).await;
        let client = HarmontClient::with_base_url("bad_token", server.uri());
        let err = client.create_api_token("test").await.unwrap_err();
        assert!(matches!(err, crate::HarmontError::Unauthorized));
    }
}
