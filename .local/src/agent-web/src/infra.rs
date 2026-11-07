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
/// kept as a failed gather is, inside the answer.
#[derive(Default)]
pub struct Cache(ReadCache<(Infra, String), CACHE_SECS>);

impl Cache {
    async fn answer(&self) -> Arc<(Infra, String)> {
        let read = async {
            let infra = off(hub_core::infra::gather)
                .await
                .unwrap_or_else(|e| Infra {
                    error: Some(e),
                    ..Default::default()
                });
            let body = serde_json::to_string(&infra).unwrap_or_else(|e| {
                serde_json::json!({"ok": false, "error": e.to_string()}).to_string()
            });
            (infra, body)
        };
        self.0.keep((), read).await
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
