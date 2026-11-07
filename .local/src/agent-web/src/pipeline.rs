//! The flow strip's gauge half: `hub_core::pipeline`, the reader the hub TUI uses, cached here as
//! Infra's is (Prometheus has no push). Home and the Queue tab join it to the live queue through
//! `hub_core::flow::Strip`, so both pages draw one strip.

use std::time::{Duration, Instant};

use hub_core::pipeline::Pipeline;
use tokio::sync::Mutex;

/// As Infra's cache: a reload inside this window reuses the last answer.
const CACHE: Duration = Duration::from_secs(30);

pub type Read = Result<Option<Pipeline>, String>;

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, Read)>>);

impl Cache {
    pub async fn get(&self) -> Read {
        let mut c = self.0.lock().await;
        if let Some((at, r)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return r.clone();
            }
        }
        let r = tokio::task::spawn_blocking(hub_core::pipeline::read)
            .await
            .unwrap_or_else(|e| Err(e.to_string()));
        *c = Some((Instant::now(), r.clone()));
        r
    }
}
