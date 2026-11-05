//! The Infra tab: the hub board's infra pages (`hub`, Prefix i) for the browser. The questions
//! and the judging of the answer are hub-core's `infra::gather`, shared with the TUI; this
//! module only caches the answer as JSON.

use std::time::{Duration, Instant};

use hub_core::infra::Infra;
use tokio::sync::Mutex;

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again.
const CACHE: Duration = Duration::from_secs(30);

/// The last answer, as hub-core's struct (Home joins it) and as JSON (the Infra tab serves it),
/// and when it was made. Holding the lock while Prometheus is asked also folds concurrent
/// requests into one round of queries.
#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, Infra, String)>>);

impl Cache {
    async fn answer(&self) -> (Infra, String) {
        let mut c = self.0.lock().await;
        if let Some((at, infra, body)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return (infra.clone(), body.clone());
            }
        }
        let infra = tokio::task::spawn_blocking(hub_core::infra::gather)
            .await
            .unwrap_or_else(|e| Infra {
                error: Some(e.to_string()),
                ..Default::default()
            });
        let body = serde_json::to_string(&infra).unwrap_or_else(|e| {
            serde_json::json!({"ok": false, "error": e.to_string()}).to_string()
        });
        *c = Some((Instant::now(), infra.clone(), body.clone()));
        (infra, body)
    }

    /// The Infra tab's answer, as JSON.
    pub async fn get(&self) -> String {
        self.answer().await.1
    }

    /// The same answer for Home's health strip and red-now rows.
    pub async fn infra(&self) -> Infra {
        self.answer().await.0
    }
}
