//! The flow strip's gauge half: `hub_core::pipeline`, the reader the hub TUI uses, cached here as
//! Infra's is (Prometheus has no push). Home and the Queue tab join it to the live queue through
//! `hub_core::flow::Strip`, so both pages draw one strip.

use hub_core::pipeline::Pipeline;

use crate::cache::{off, ReadCache};

/// As Infra's cache: a reload inside this window reuses the last answer.
const CACHE_SECS: u64 = 30;

pub type Read = Result<Option<Pipeline>, String>;

#[derive(Default)]
pub struct Cache(ReadCache<Read, CACHE_SECS>);

impl Cache {
    /// The gauges, an error among them: a failed read is kept too, so a Prometheus that is
    /// down is asked once a window and not on every reload. A panic in the read is not kept.
    pub async fn get(&self) -> Read {
        match self.0.get((), off(hub_core::pipeline::read)).await {
            Ok(r) => (*r).clone(),
            Err(e) => Err(e),
        }
    }
}
