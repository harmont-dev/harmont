//! Build submission and status.

use std::collections::HashMap;
use base64::Engine;
use crate::{HarmontClient, Result};
use crate::models::Build;

/// A new build of a *local* worktree: the v0 IR is pre-rendered and the
/// source is uploaded inline as a gzipped tarball (base64 `source_b64`).
#[derive(Debug, Clone)]
pub struct NewBuild {
    /// Organization slug.
    pub org: String,
    /// Pipeline slug.
    pub pipeline: String,
    /// Source branch recorded on the build.
    pub branch: String,
    /// Source commit SHA recorded on the build.
    pub commit: String,
    /// Optional build/commit message.
    pub message: Option<String>,
    /// Pre-rendered v0 IR JSON (`{"version":"0","steps":[...]}`).
    pub pipeline_ir: String,
    /// Raw gzipped tar bytes of the worktree (will be base64-encoded).
    pub source_tgz: Vec<u8>,
    /// Build-level environment variables.
    pub env: HashMap<String, String>,
}

/// A new build addressed by the repo-natural identity `(repo_name, source_slug)`
/// rather than the org-global pipeline slug — the `hm run` path. A repo-local
/// client knows its git remote and its in-repo pipeline name, but not the
/// namespaced slug the server assigns on discovery.
#[derive(Debug, Clone)]
pub struct NewRepoBuild {
    /// Organization slug.
    pub org: String,
    /// Repository `owner/repo`, from the worktree's git remote.
    pub repo_name: String,
    /// In-repo pipeline name — the `@hm.pipeline("…")` slug.
    pub source_slug: String,
    /// Source branch recorded on the build.
    pub branch: String,
    /// Source commit SHA recorded on the build.
    pub commit: String,
    /// Optional build/commit message.
    pub message: Option<String>,
    /// Pre-rendered v0 IR JSON.
    pub pipeline_ir: String,
    /// Raw gzipped tar bytes of the worktree (will be base64-encoded).
    pub source_tgz: Vec<u8>,
    /// Build-level environment variables.
    pub env: HashMap<String, String>,
}

impl HarmontClient {
    /// Submit a build from a local worktree. Returns the created [`Build`].
    pub async fn submit_build(&self, b: NewBuild) -> Result<Build> {
        let source_b64 = base64::engine::general_purpose::STANDARD.encode(&b.source_tgz);
        let url = format!(
            "{}/api/v0/organizations/{}/pipelines/{}/builds",
            self.base, b.org, b.pipeline
        );
        let body = serde_json::json!({
            "branch": b.branch, "commit": b.commit, "message": b.message,
            "source": "api", "pipeline_ir": b.pipeline_ir,
            "source_b64": source_b64, "env": b.env,
        });
        let resp = self.http.post(&url).json(&body).send().await?;
        self.parse_json(resp).await
    }

    /// Submit a build addressed by `(repo_name, source_slug)` — the `hm run`
    /// path. Returns the created [`Build`], whose `pipeline_slug` is the
    /// resolved global slug (use it to watch/cancel). Errors carry the server's
    /// structured `code`/`message`, including a missing-pipeline 404.
    pub async fn submit_repo_build(&self, b: NewRepoBuild) -> Result<Build> {
        let source_b64 = base64::engine::general_purpose::STANDARD.encode(&b.source_tgz);
        let url = format!("{}/api/v0/organizations/{}/builds", self.base, b.org);
        let body = serde_json::json!({
            "repo_name": b.repo_name, "source_slug": b.source_slug,
            "branch": b.branch, "commit": b.commit, "message": b.message,
            "source": "api", "pipeline_ir": b.pipeline_ir,
            "source_b64": source_b64, "env": b.env,
        });
        let resp = self.http.post(&url).json(&body).send().await?;
        self.parse_json_structured(resp).await
    }

    /// Fetch a build by its pipeline-scoped number.
    pub async fn get_build(&self, org: &str, pipeline: &str, number: i64) -> Result<Build> {
        let url = format!("{}/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}", self.base);
        let resp = self.http.get(&url).send().await?;
        self.parse_json(resp).await
    }

    /// List the jobs of a build.
    pub async fn list_jobs(&self, org: &str, pipeline: &str, number: i64)
        -> Result<Vec<crate::models::Job>>
    {
        let url = format!("{}/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/jobs", self.base);
        let resp = self.http.get(&url).send().await?;
        #[derive(serde::Deserialize)]
        struct Wrap { data: Vec<crate::models::Job> }
        let w: Wrap = self.parse_json(resp).await?;
        Ok(w.data)
    }

    /// Cancel a running build.
    pub async fn cancel_build(&self, org: &str, pipeline: &str, number: i64) -> Result<()> {
        let url = format!("{}/api/v0/organizations/{org}/pipelines/{pipeline}/builds/{number}/cancel", self.base);
        let resp = self.http.put(&url).send().await?;
        let _: serde_json::Value = self.parse_json(resp).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use crate::HarmontClient;
    use wiremock::matchers::{method, path, body_partial_json};
    use wiremock::{Mock, MockServer, ResponseTemplate};
    use serde_json::json;

    #[tokio::test]
    async fn submit_build_posts_source_b64_and_pipeline_ir() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/organizations/acme/pipelines/ci/builds"))
            .and(body_partial_json(json!({
                "branch": "feat/x", "commit": "abc123", "source": "api",
                "pipeline_ir": "{\"version\":\"0\",\"steps\":[]}",
                "source_b64": base64::engine::general_purpose::STANDARD.encode(b"fake-tarball"),
            })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({
                "number": 42, "state": "scheduled", "pipeline_slug": "ci",
                "branch": "feat/x", "commit": "abc123",
                "message": null, "source": "api",
                "created_at": "2026-06-04T00:00:00Z"
            })))
            .mount(&server).await;

        let client = HarmontClient::with_base_url("hm_test", server.uri());
        let req = NewBuild {
            org: "acme".into(), pipeline: "ci".into(),
            branch: "feat/x".into(), commit: "abc123".into(),
            message: None,
            pipeline_ir: r#"{"version":"0","steps":[]}"#.into(),
            source_tgz: b"fake-tarball".to_vec(),
            env: Default::default(),
        };
        let build = client.submit_build(req).await.expect("submit ok");
        assert_eq!(build.number, 42);
        assert_eq!(build.state.to_string(), "scheduled");
    }

    #[tokio::test]
    async fn unauthorized_maps_cleanly() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(401))
            .mount(&server).await;
        let client = HarmontClient::with_base_url("bad", server.uri());
        let err = client.get_build("acme", "ci", 1).await.unwrap_err();
        assert!(matches!(err, crate::HarmontError::Unauthorized));
    }

    #[tokio::test]
    async fn rejected_build_maps_to_api_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(422).set_body_json(serde_json::json!({
                "error": {"code": "build_rejected", "message": "bad IR"}
            }))).mount(&server).await;
        let client = HarmontClient::with_base_url("hm_test", server.uri());
        let req = NewBuild { org:"a".into(),pipeline:"c".into(),branch:"b".into(),
            commit:"x".into(),message:None,pipeline_ir:"{}".into(),
            source_tgz:vec![],env:Default::default() };
        let err = client.submit_build(req).await.unwrap_err();
        assert!(matches!(err, crate::HarmontError::Api { status: 422, .. }));
    }

    #[tokio::test]
    async fn submit_repo_build_posts_to_org_builds_with_repo_and_source() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/organizations/acme/builds"))
            .and(body_partial_json(json!({
                "repo_name": "harmont-dev/acme", "source_slug": "ci",
                "branch": "main", "commit": "abc123", "source": "api",
                "pipeline_ir": "{\"version\":\"0\",\"steps\":[]}",
            })))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({
                "number": 7, "state": "scheduled", "pipeline_slug": "harmont-dev-acme-ci",
                "branch": "main", "commit": "abc123", "message": null, "source": "api",
                "created_at": "2026-06-10T00:00:00Z"
            })))
            .mount(&server).await;

        let client = HarmontClient::with_base_url("hm_test", server.uri());
        let req = NewRepoBuild {
            org: "acme".into(), repo_name: "harmont-dev/acme".into(), source_slug: "ci".into(),
            branch: "main".into(), commit: "abc123".into(), message: None,
            pipeline_ir: r#"{"version":"0","steps":[]}"#.into(),
            source_tgz: b"fake-tarball".to_vec(), env: Default::default(),
        };
        let build = client.submit_repo_build(req).await.expect("submit ok");
        assert_eq!(build.number, 7);
        assert_eq!(build.pipeline_slug, "harmont-dev-acme-ci");
    }

    #[tokio::test]
    async fn submit_repo_build_404_surfaces_structured_code() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(404).set_body_json(json!({
                "error": {"code": "pipeline_not_found", "message": "No pipeline `ci` found …"}
            }))).mount(&server).await;
        let client = HarmontClient::with_base_url("hm_test", server.uri());
        let req = NewRepoBuild {
            org: "a".into(), repo_name: "o/r".into(), source_slug: "ci".into(),
            branch: "b".into(), commit: "x".into(), message: None,
            pipeline_ir: "{}".into(), source_tgz: vec![], env: Default::default(),
        };
        let err = client.submit_repo_build(req).await.unwrap_err();
        assert!(matches!(
            err,
            crate::HarmontError::Api { status: 404, ref code, .. } if code == "pipeline_not_found"
        ));
    }

    #[tokio::test]
    async fn list_jobs_unwraps_data() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v0/organizations/acme/pipelines/ci/builds/42/jobs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "data": [{"id":"00000000-0000-0000-0000-000000000001","state":"running",
                          "name":"build","depends_on":[],"created_at":"2026-06-04T00:00:00Z",
                          "soft_failed": false}]
            }))).mount(&server).await;
        let client = HarmontClient::with_base_url("hm_test", server.uri());
        let jobs = client.list_jobs("acme","ci",42).await.expect("ok");
        assert_eq!(jobs.len(), 1);
    }
}
