//! The Alerts tab: what is firing, who owns its fix, what fired lately and every watch, from
//! `hub_core::alerts`, the reader the hub TUI's Alerts tab uses. The firing rows are filtered
//! and sorted here by `hub_core::table`, so the page only draws.
//!
//! Prometheus and Alertmanager come from the Infra tab's cache (`infra::CACHE_SECS`).
//! `fleet-bench reds` takes about 2s and a fix moves in minutes, so its answer is kept for
//! `REDS_SECS` or until a queue write (a fix item filed or moved). The watches and the pages
//! ledger are files, read on every request, so the push that a watch changed state is answered
//! with that state.

use hub_core::alerts::{self, Alert, Alerts};
use hub_core::reds::{self, Reds};
use hub_core::session_actions::System;
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::cache::{off, EventCache};
use crate::infra;

const REDS_SECS: u64 = 120;
/// A fix item filed, started or finished outdates the fixes and every owner.
const KINDS: [&str; 1] = ["queue"];

/// The firing table's view, the same keys the page keeps in its URL.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// The read with the view applied to its firing rows.
#[derive(Serialize)]
struct Shown<'a> {
    #[serde(flatten)]
    alerts: &'a Alerts,
    rows: Vec<&'a Alert>,
    table: Summary,
}

pub struct Cache(EventCache<Result<Reds, String>, REDS_SECS>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS))
    }

    /// The tab as `q` views it. A failed fixes read is shown and not kept.
    pub async fn get(&self, infra: &infra::Cache, q: Query) -> String {
        let fixes = self
            .0
            .get_if((), || reds::read(&System), Result::is_ok)
            .await
            .and_then(|r| (*r).clone());
        let infra = infra.infra().await;
        let now = chrono::Utc::now().timestamp();
        match off(move || alerts::read(&infra, fixes, now)).await {
            Ok(a) => render(&a, &q),
            Err(e) => serde_json::json!({ "rows": [], "errors": [e] }).to_string(),
        }
    }
}

fn render(a: &Alerts, q: &Query) -> String {
    let view = View::new::<Alert>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&a.firing);
    serde_json::to_string(&Shown {
        alerts: a,
        rows,
        table,
    })
    .unwrap_or_else(|e| serde_json::json!({ "rows": [], "errors": [e.to_string()] }).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_body_is_the_tab_with_the_firing_rows_its_view_keeps() {
        let row = |what: &str, state: &str| Alert {
            what: what.into(),
            source: "sentinel".into(),
            state: state.into(),
            ..Default::default()
        };
        let a = Alerts {
            firing: vec![row("delta", "no owner"), row("echo", "error")],
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(
            &a,
            &Query {
                s: "error".into(),
                ..Default::default()
            },
        ))
        .unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["what"], "echo");
        assert_eq!(
            v["firing"].as_array().unwrap().len(),
            2,
            "the whole read too"
        );
        assert_eq!(v["table"]["total"], 2);
        assert!(v["counts"].is_object() && v["watches"].is_array());
    }
}
