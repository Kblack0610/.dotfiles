//! Home's "Since last night": `hub_core::briefing::night`, the reader the hub TUI's Home uses,
//! over the same state, queue and board Home reads, with Infra's cached answer. It reads the
//! runs, calls, day records and Prometheus, none of which pushes, so it is cached as the
//! gauge read is (pipeline.rs) and Home's own refresh re-reads it.

use std::time::Instant;

use tokio::sync::Mutex;

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, String)>>);

impl Cache {
    pub async fn get(&self, infra: hub_core::infra::Infra) -> String {
        let mut c = self.0.lock().await;
        if let Some((at, b)) = c.as_ref() {
            if at.elapsed() < hub_core::briefing::NIGHT_REFRESH {
                return b.clone();
            }
        }
        let b = tokio::task::spawn_blocking(move || {
            let now = chrono::Utc::now().timestamp();
            let (state, queue, board, _) = hub_core::home::gather(false);
            let home = hub_core::home::build(&state, Some(&queue), Some(&board), Some(&infra));
            let n = hub_core::briefing::since_last_night(now, state, queue, home);
            serde_json::to_string(&n).map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|r| r);
        match b {
            Ok(b) => {
                *c = Some((Instant::now(), b.clone()));
                b
            }
            // A failed read is not kept: the next reload tries again.
            Err(e) => serde_json::json!({ "error": e }).to_string(),
        }
    }
}
