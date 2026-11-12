//! The Alerts tab: what is firing, who owns its fix, what fired lately and every watch, from
//! `hub_core::alerts`, the reader the hub TUI's Alerts tab uses. Firing, Watches and History are
//! filtered and sorted here by `hub_core::table`, so the page only draws.
//!
//! Prometheus and Alertmanager come from the Infra tab's cache (`infra::CACHE_SECS`).
//! `fleet-bench reds` takes about 2s and a fix moves in minutes, so its answer is kept for
//! `REDS_SECS` or until a queue write (a fix item filed or moved). The watches and the pages
//! ledger are files, read on every request, so the push that a watch changed state is answered
//! with that state.

use hub_core::actions::Action;
use hub_core::alerts::{self, Alert, Alerts};
use hub_core::fleet::runner::Watch;
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

/// Each table's view, the same keys the page keeps in its URL. Three tables share the tab, so
/// Watches' are w-prefixed (`wq`, `ws`, `wsort`, `wdir`), History's h-prefixed, and Firing keeps
/// the plain ones, so links to it stay valid.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
    pub wq: String,
    pub ws: String,
    pub wsort: String,
    pub wdir: String,
    pub hq: String,
    pub hs: String,
    pub hsort: String,
    pub hdir: String,
}

/// The read with each view applied: `watches` and `history` are the rows their views keep, and
/// `firing` stays whole beside the firing `rows`.
#[derive(Serialize)]
struct Shown<'a> {
    #[serde(flatten)]
    alerts: &'a Alerts,
    rows: Vec<&'a Alert>,
    table: Summary,
    watches_table: Summary,
    history_table: Summary,
}

pub struct Cache(EventCache<Result<Reds, String>, REDS_SECS>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS))
    }

    /// The read, or why it panicked. A failed fixes read is shown and not kept.
    pub(crate) async fn read(&self, infra: &infra::Cache) -> Result<Alerts, String> {
        let fixes = self
            .0
            .get_if((), || reds::read(&System), Result::is_ok)
            .await
            .and_then(|r| (*r).clone());
        let infra = infra.infra().await;
        let now = chrono::Utc::now().timestamp();
        off(move || alerts::read(&infra, fixes, now)).await
    }

    /// The tab as `q` views it.
    pub async fn get(&self, infra: &infra::Cache, q: Query) -> String {
        match self.read(infra).await {
            Ok(a) => render(a, &q),
            Err(e) => serde_json::json!({ "rows": [], "errors": [e] }).to_string(),
        }
    }

    /// What fires now, one alert a place, for a machine page's alerts.
    pub async fn firing(&self, infra: &infra::Cache) -> Result<Vec<Alert>, String> {
        self.read(infra).await.map(|a| a.pages().cloned().collect())
    }
}

fn render(mut a: Alerts, q: &Query) -> String {
    let view = View::new::<Watch>(&q.wq, &q.ws, &q.wsort, &q.wdir);
    let (rows, watches_table) = view.summary(&a.watches);
    a.watches = rows.into_iter().cloned().collect();
    let view = View::new::<Action>(&q.hq, &q.hs, &q.hsort, &q.hdir);
    let (rows, history_table) = view.summary(&a.history);
    a.history = rows.into_iter().cloned().collect();
    let view = View::new::<Alert>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&a.firing);
    serde_json::to_string(&Shown {
        alerts: &a,
        rows,
        table,
        watches_table,
        history_table,
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
            a,
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

    #[test]
    fn watches_and_history_each_take_their_own_view_keys_and_firing_keeps_its_own() {
        use hub_core::actions::Action;
        use hub_core::fleet::runner::Watch;
        let watch = |name: &str, state: &str, project: &str| Watch {
            name: name.into(),
            state: state.into(),
            project: project.into(),
            ..Default::default()
        };
        let page = |text: &str| Action {
            at: 1,
            actor: "sentinel".into(),
            verb: "tripped".into(),
            text: text.into(),
            priority: None,
            reference: None,
            source: "agent-notify".into(),
        };
        let a = Alerts {
            watches: vec![
                watch("board-open", "TRIP", "dotfiles"),
                watch("dream", "ERROR", ""),
                watch("disk", "OK", "home-config"),
            ],
            history: vec![page("Sentinel: board-open"), page("Sentinel: disk")],
            ..Default::default()
        };
        let q = Query {
            ws: "ok".into(),
            hq: "board".into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(a.clone(), &q)).unwrap();
        assert_eq!(v["watches"].as_array().unwrap().len(), 1);
        assert_eq!(v["watches"][0]["name"], "disk");
        assert_eq!(v["watches_table"]["total"], 3);
        assert_eq!(v["watches_table"]["state"], "ok");
        assert_eq!(v["history"].as_array().unwrap().len(), 1);
        assert_eq!(v["history"][0]["text"], "Sentinel: board-open");
        assert_eq!(v["history_table"]["total"], 2);
        // Negative control: the plain keys are Firing's, and leave both tables whole.
        let plain = Query {
            q: "board".into(),
            s: "ok".into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(a, &plain)).unwrap();
        assert_eq!(v["watches"].as_array().unwrap().len(), 3);
        assert_eq!(v["history"].as_array().unwrap().len(), 2);
    }
}
