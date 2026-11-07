//! The Infra tab: the hub board's infra pages (`hub`, Prefix i) for the browser. The questions
//! and the judging of the answer are hub-core's `infra::gather`, shared with the TUI; this
//! module only caches the answer as JSON.

use std::sync::Arc;

use hub_core::infra::Infra;

use crate::cache::{off, ReadCache};

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again.
const CACHE_SECS: u64 = 30;

/// The last answer, as hub-core's struct (Home joins it) and as JSON (the Infra tab serves it),
/// kept as a failed gather is, inside the answer. A panic in the gather is shown, not kept.
#[derive(Default)]
pub struct Cache(ReadCache<(Infra, String), CACHE_SECS>);

/// The answer beside its JSON, made once for every request that shares it.
fn with_body(infra: Infra) -> (Infra, String) {
    let body = serde_json::to_string(&infra)
        .unwrap_or_else(|e| serde_json::json!({"ok": false, "error": e.to_string()}).to_string());
    (infra, body)
}

impl Cache {
    async fn answer(&self) -> Arc<(Infra, String)> {
        let read = async { off(hub_core::infra::gather).await.map(with_body) };
        self.0.get((), read).await.unwrap_or_else(|e| {
            Arc::new(with_body(Infra {
                error: Some(e),
                ..Default::default()
            }))
        })
    }

    /// The Infra tab's answer, as JSON.
    pub async fn get(&self) -> String {
        self.answer().await.1.clone()
    }

    /// The same answer for Home's health strip and red-now rows.
    pub async fn infra(&self) -> Infra {
        self.answer().await.0.clone()
    }
}
