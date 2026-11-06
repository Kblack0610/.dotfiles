//! The Queue tab's pipeline line: `hub_core::pipeline`, the reader the hub TUI's Queue tab uses,
//! worded once in hub-core and cached here as Infra's is (Prometheus has no push).

use std::time::{Duration, Instant};

use tokio::sync::Mutex;

/// As Infra's cache: a reload inside this window reuses the last answer.
const CACHE: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, String)>>);

/// The answer as JSON: `lines` as hub-core words them (`pipeline -` when the gauges are absent),
/// the counts, the read error if any, and Grafana's base for the page's link.
pub fn body(read: Result<Option<hub_core::pipeline::Pipeline>, String>) -> String {
    let (pipe, error) = match read {
        Ok(p) => (p, None),
        Err(e) => (None, Some(e)),
    };
    serde_json::json!({
        "lines": hub_core::pipeline::lines(pipe.as_ref()),
        "pipeline": pipe,
        "error": error,
        "grafana": hub_core::infra::grafana(),
    })
    .to_string()
}

impl Cache {
    pub async fn get(&self) -> String {
        let mut c = self.0.lock().await;
        if let Some((at, b)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return b.clone();
            }
        }
        let b = tokio::task::spawn_blocking(|| body(hub_core::pipeline::read()))
            .await
            .unwrap_or_else(|e| body(Err(e.to_string())));
        *c = Some((Instant::now(), b.clone()));
        b
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_gauges_say_pipeline_dash_and_an_error_says_why() {
        let v: serde_json::Value = serde_json::from_str(&body(Ok(None))).unwrap();
        assert_eq!(v["lines"], serde_json::json!(["pipeline -"]));
        assert!(v["pipeline"].is_null() && v["error"].is_null());
        let v: serde_json::Value = serde_json::from_str(&body(Err("no prom".into()))).unwrap();
        assert_eq!(v["lines"], serde_json::json!(["pipeline -"]));
        assert_eq!(v["error"], "no prom");
    }
}
