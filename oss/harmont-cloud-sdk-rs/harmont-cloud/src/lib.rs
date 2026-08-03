//! High-level Rust client for the Harmont Cloud API.
//!
//! Wraps the generated [`harmont_cloud_raw`] crate with ergonomic types,
//! bearer auth, local-worktree build submission, status polling, and live
//! SSE log streaming (the log stream is not part of the OpenAPI spec).
#![forbid(unsafe_code)]

mod error;
pub use error::{HarmontError, Result};

pub use harmont_cloud_raw::types;

pub mod client;
pub use client::HarmontClient;

pub mod models;
pub mod builds;
pub mod logs;
pub mod auth;
