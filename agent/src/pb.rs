//! Re-exports of the prost-build generated protobuf types.

#![allow(clippy::all, dead_code, unused_imports)]

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/harmont.agent.v1.rs"));
}

#[allow(unused_imports)]
pub use v1::*;
