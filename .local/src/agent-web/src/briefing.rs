//! Home's "Since last night": `hub_core::briefing::night`, the reader the hub TUI's Home uses,
//! over the state, queue and Home that `/api/home` reads (`home_inputs`), so the two never join
//! the fleet state twice. It reads the runs, calls, day records and Prometheus, none of which
//! pushes, so it is cached as the gauge read is (pipeline.rs) and Home's own refresh re-reads it.

use std::future::Future;

use crate::cache::{off, ReadCache};

pub struct Cache(ReadCache<String, { hub_core::briefing::NIGHT_REFRESH.as_secs() }>);

impl Default for Cache {
    fn default() -> Self {
        Self(ReadCache::new("briefing"))
    }
}

impl Cache {
    /// A failed read is not kept: the next reload tries again. `inputs` is awaited only when
    /// nothing is kept.
    pub async fn get(
        &self,
        inputs: impl Future<
                Output = Result<
                    (
                        hub_core::home::Home,
                        serde_json::Value,
                        hub_core::queue::Queue,
                    ),
                    String,
                >,
            > + Send
            + 'static,
    ) -> String {
        let read = async move {
            let (home, state, queue) = inputs.await?;
            off(move || {
                let now = chrono::Utc::now().timestamp();
                let n = hub_core::briefing::since_last_night(now, state, queue, home);
                serde_json::to_string(&n).map_err(|e| e.to_string())
            })
            .await
            .and_then(|r| r)
        };
        match self.0.get((), read).await {
            Ok(b) => (*b).clone(),
            Err(e) => serde_json::json!({ "error": e }).to_string(),
        }
    }
}
