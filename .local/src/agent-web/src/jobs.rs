//! The Jobs tab: every job that runs on its own, from hub-core's `jobs`, and one run's log.

use std::time::{Duration, Instant};

use hub_core::jobs::{self, LogRef, Opts, Paths, Source};
use serde::Deserialize;
use tokio::sync::Mutex;

/// The default list folds concurrent tabs and quick reloads into one collection; a one-job
/// history (`name=`) is asked for by a click and is always fresh.
const CACHE: Duration = Duration::from_secs(15);
/// The longest history a request may ask for: the journal and the exporter hold about a day,
/// the ledgers longer.
const MAX_WINDOW_SECS: i64 = 7 * 24 * 3600;

#[derive(Deserialize, Default)]
pub struct JobsQuery {
    pub name: Option<String>,
    pub window: Option<i64>,
    pub source: Option<Source>,
}

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, String)>>);

fn collect(q: JobsQuery) -> String {
    let mut opts = Opts {
        name: q.name.filter(|n| !n.is_empty()),
        ..Opts::default()
    };
    if let Some(w) = q.window {
        opts.window_secs = w.clamp(60, MAX_WINDOW_SECS);
    }
    if let Some(s) = q.source {
        opts.sources = vec![s];
    }
    let out = jobs::collect(&Paths::from_env(), &opts);
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when collecting itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "jobs": [], "errors": [e] }).to_string()
}

impl Cache {
    pub async fn get(&self, q: JobsQuery) -> String {
        let plain = q.name.is_none() && q.window.is_none() && q.source.is_none();
        if !plain {
            return tokio::task::spawn_blocking(move || collect(q))
                .await
                .unwrap_or_else(|e| failed(e.to_string()));
        }
        let mut c = self.0.lock().await;
        if let Some((at, body)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return body.clone();
            }
        }
        let body = tokio::task::spawn_blocking(move || collect(q))
            .await
            .unwrap_or_else(|e| failed(e.to_string()));
        *c = Some((Instant::now(), body.clone()));
        body
    }
}

/// The log behind a row. `raw` is the row's own `log` object as JSON, which `read_log` checks.
/// The outer error is a reference that does not parse; the inner one, a log that cannot be read.
pub async fn log(raw: String) -> Result<Result<String, String>, String> {
    let r: LogRef = serde_json::from_str(&raw).map_err(|e| format!("bad log reference: {e}"))?;
    tokio::task::spawn_blocking(move || jobs::read_log(&Paths::from_env(), &r))
        .await
        .map_err(|e| e.to_string())
}
