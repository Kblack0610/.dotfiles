//! The Infra tab: the hub board's Overview (`hub`, its tab 1) for the browser. The questions
//! and the judging of the answer are hub-core's `infra::gather`, shared with the TUI; this
//! module only caches the answer as JSON.

use std::time::{Duration, Instant};

use tokio::sync::Mutex;

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again.
const CACHE: Duration = Duration::from_secs(30);

/// The last answer as JSON, and when it was made. Holding the lock while Prometheus is asked
/// also folds concurrent requests into one round of queries.
#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, String)>>);

impl Cache {
    pub async fn get(&self) -> String {
        let mut c = self.0.lock().await;
        if let Some((at, body)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return body.clone();
            }
        }
        let body = match tokio::task::spawn_blocking(hub_core::infra::gather).await {
            Ok(infra) => serde_json::to_string(&infra).unwrap_or_else(|e| {
                serde_json::json!({"ok": false, "error": e.to_string()}).to_string()
            }),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}).to_string(),
        };
        *c = Some((Instant::now(), body.clone()));
        body
    }
}
