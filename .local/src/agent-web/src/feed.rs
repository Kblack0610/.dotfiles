//! Log's Actions section: everything the fleet's machinery did (shepherd, dispatch, pages, failed
//! runs, the queue), read by `hub_core::actions`, the same reader as `hub actions` and the
//! briefing's digest.

use crate::cache::EventCache;
use axum::extract::{Query, State};
use axum::Json;
use hub_core::actions::{self, Action, Gathered};
use hub_core::table::View;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::broadcast;

use crate::Shared;

const HOURS_DEFAULT: i64 = 24;
/// A week: the shepherd log's busiest days hold about 1000 entries.
const HOURS_MAX: i64 = 168;
/// The event kinds that mean a ledger this section reads was written (`outbox` is also the
/// ingest record's).
const KINDS: [&str; 4] = ["actions", "fleet", "queue", "outbox"];
/// The backstop for a read no event outdated, should the watcher be down.
const READ_FOR_SECS: u64 = 15;

#[derive(Deserialize)]
pub struct Q {
    hours: Option<i64>,
    /// The table's view, as hub_core::table reads it.
    #[serde(default)]
    q: String,
    #[serde(default)]
    s: String,
    #[serde(default)]
    sort: String,
    #[serde(default)]
    dir: String,
}

fn window(hours: Option<i64>) -> i64 {
    hours.unwrap_or(HOURS_DEFAULT).clamp(1, HOURS_MAX) * 3600
}

/// The rows `q`'s view keeps and the table's summary; `counts` still covers the whole window.
fn shown(g: &Gathered, q: &Q) -> Value {
    let view = View::new::<Action>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&g.actions);
    json!({ "actions": rows, "counts": g.counts, "errors": g.errors, "table": table })
}

fn read(span: i64) -> Gathered {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    actions::read(now - span)
}

/// The last read, so typing in the search box does not re-read every ledger: `agent-queue list`
/// alone is half a second under load.
pub struct Cache(EventCache<Gathered, READ_FOR_SECS, i64>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS))
    }

    /// `span` seconds of actions.
    async fn gathered<F>(&self, span: i64, read: F) -> Arc<Gathered>
    where
        F: FnOnce(i64) -> Gathered + Send + 'static,
    {
        self.0
            .get(span, move || read(span))
            .await
            .unwrap_or_else(|e| {
                Arc::new(Gathered {
                    errors: vec![e],
                    ..Gathered::default()
                })
            })
    }
}

pub async fn get(State(s): State<Shared>, Query(q): Query<Q>) -> Json<Value> {
    let g = s.actions.gathered(window(q.hours), read).await;
    Json(shown(&g, &q))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_defaults_to_a_day_and_is_clamped_to_a_week() {
        assert_eq!(window(None), 24 * 3600);
        assert_eq!(window(Some(0)), 3600);
        assert_eq!(window(Some(-5)), 3600);
        assert_eq!(window(Some(72)), 72 * 3600);
        assert_eq!(window(Some(10_000)), 168 * 3600);
    }

    #[tokio::test]
    async fn a_read_is_kept_until_an_event_says_a_ledger_changed() {
        let (tx, rx) = broadcast::channel(8);
        let c = Cache::new(rx);
        let reads = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = || {
            let reads = reads.clone();
            move |_| {
                reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Gathered::default()
            }
        };
        let n = || reads.load(std::sync::atomic::Ordering::SeqCst);
        c.gathered(3600, count()).await;
        c.gathered(3600, count()).await;
        assert_eq!(n(), 1, "a view change reuses the read");
        tx.send(r#"{"kind":"transcript"}"#.to_string()).unwrap();
        c.gathered(3600, count()).await;
        assert_eq!(n(), 1, "an event about something else does not outdate it");
        tx.send(r#"{"kind":"queue"}"#.to_string()).unwrap();
        c.gathered(3600, count()).await;
        assert_eq!(n(), 2, "a ledger's event does");
        c.gathered(7200, count()).await;
        assert_eq!(n(), 3, "another window is another read");
        let failed = c.gathered(3600, |_| panic!("read failed")).await;
        assert_eq!(failed.errors.len(), 1);
        c.gathered(3600, count()).await;
        assert_eq!(n(), 4, "a failed read is not kept");
    }

    #[test]
    fn the_view_narrows_the_rows_and_not_the_window_counts() {
        let row = |at, actor: &str| Action {
            at,
            actor: actor.into(),
            verb: "nudge".into(),
            text: "t".into(),
            priority: None,
            failed: false,
            reference: None,
            source: "shepherd".into(),
        };
        let actions = vec![row(2, "shepherd"), row(1, "dispatch")];
        let g = Gathered {
            counts: actions::counts(&actions),
            actions,
            ..Gathered::default()
        };
        let q = Q {
            hours: None,
            q: "actor:shepherd".into(),
            s: String::new(),
            sort: String::new(),
            dir: String::new(),
        };
        let v = shown(&g, &q);
        assert_eq!(v["actions"].as_array().unwrap().len(), 1);
        assert_eq!(v["table"]["shown"], 1);
        assert_eq!(v["table"]["total"], 2);
        assert_eq!(v["counts"]["dispatch"]["nudge"], 1);
    }
}
