//! The Sessions tab's table and header, from hub-core's `session_table` and `capacity`. The rows
//! are filtered and sorted here by `hub_core::table`, so the page only draws.

use std::sync::Arc;

use hub_core::boards;
use hub_core::capacity::{self, Capacity};
use hub_core::session_actions::{self as actions, System};
use hub_core::session_page::{self, SessionPage};
use hub_core::session_table::{self, SessionRow};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cache::{off, ReadCache};

/// Folds concurrent tabs, quick reloads and every keystroke in the search into one read.
const CACHE_SECS: u64 = 15;
/// The header's sources (the last pass's headroom, the timers, the shepherd's stats) move once a
/// minute at most.
const CAPACITY_SECS: u64 = 60;

/// The table view, the same keys the page keeps in its URL.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct TableQuery {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// Every row, the state document under it and what could not be read.
#[derive(Default)]
struct Read {
    rows: Vec<SessionRow>,
    state: Vec<Value>,
    buckets: Vec<String>,
    errors: Vec<String>,
}

#[derive(Serialize)]
struct Shown<'a> {
    rows: Vec<&'a SessionRow>,
    /// The state document's bucket order, for the page's colours and lanes.
    buckets: &'a [String],
    errors: &'a [String],
    table: Summary,
    /// What the shown rows cost (`session_table::spend`), for the overview row.
    spend_usd: f64,
}

#[derive(Default)]
pub struct Cache {
    table: ReadCache<Read, CACHE_SECS>,
    /// The last page opened, by its id.
    page: ReadCache<Option<SessionPage>, CACHE_SECS, String>,
    capacity: ReadCache<Capacity, CAPACITY_SECS>,
}

fn render(r: &Read, q: &TableQuery) -> String {
    let view = View::new::<SessionRow>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&r.rows);
    let out = Shown {
        spend_usd: session_table::spend(rows.iter().copied()),
        rows,
        buckets: &r.buckets,
        errors: &r.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

impl Cache {
    async fn read(&self) -> Result<Arc<Read>, String> {
        let read = off(|| {
            let (state, vocab) = session_table::read_state(&boards::fleet_state());
            let feed = session_table::feed(&System, &session_table::registry());
            Read {
                rows: session_table::rows(&state, &vocab, &feed, &actions::gather(&System).agents),
                state,
                buckets: vocab.buckets().to_vec(),
                errors: feed.errors,
            }
        });
        self.table.get((), read).await
    }

    /// The view `q` asks for; every view is applied to the shared read outside the lock.
    pub async fn table(&self, q: TableQuery) -> String {
        self.read().await.map_or_else(failed, |r| render(&r, &q))
    }

    /// One session's page, or None when nothing names `id`. The open page refreshes with the
    /// list, so the last one is kept as the list's read is; a None is not kept.
    pub async fn page(&self, id: String) -> Result<Arc<Option<SessionPage>>, String> {
        let key = id.clone();
        let read = async {
            let read = self.read().await?;
            off(move || {
                session_page::read(
                    &System,
                    &boards::shepherd_dir(),
                    &id,
                    &read.rows,
                    &read.state,
                )
            })
            .await
        };
        self.page.get_if(key, read, Option::is_some).await
    }

    pub async fn capacity(&self) -> Result<Arc<Capacity>, String> {
        let read = off(|| capacity::read_fleet(&System));
        self.capacity.get((), read).await
    }

    /// Start a timer, and drop the header so the next read shows it on.
    pub async fn start(&self, name: String) -> Result<String, String> {
        let out = off(move || capacity::start(&System, &name)).await??;
        self.capacity.clear().await;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::session_table::Source;

    #[test]
    fn the_body_is_the_rows_the_view_keeps_with_its_controls() {
        let row = |key: &str, bucket: &str, source| SessionRow {
            key: key.into(),
            bucket: bucket.into(),
            source,
            ..SessionRow::default()
        };
        let r = Read {
            rows: vec![
                row("lab/a:1", "NEEDS", Source::Live),
                row("slug", "DONE", Source::Queue),
            ],
            buckets: vec!["NEEDS".into(), "DONE".into()],
            errors: vec!["session outcomes: exit 1".into()],
            ..Read::default()
        };
        let q = TableQuery {
            s: "done today".into(),
            ..TableQuery::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&r, &q)).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["key"], "slug");
        assert_eq!(v["rows"][0]["source"], "queue");
        assert_eq!(v["errors"][0], "session outcomes: exit 1");
        assert_eq!(v["table"]["state"], "done today");
        assert_eq!(v["table"]["total"], 2);
    }

    #[test]
    fn a_freqtrade_worktree_reads_trader_and_the_body_carries_the_bucket_order() {
        let doc = serde_json::json!({
            "vocab": {"buckets": ["NEEDS", "WORKING"], "in_progress": ["WORKING"]},
            "sessions": [{"target": "lab/freqtrade_trading_attempt-agent-1:1", "bucket": "WORKING",
                "session_id": "f1", "cwd": "/w/freqtrade_trading_attempt-agent-1",
                "project": "trader", "item": null}]});
        let dir = std::env::temp_dir().join(format!("agent-web-vocab-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        std::fs::write(&path, doc.to_string()).unwrap();
        let (state, vocab) = session_table::read_state(&path);
        std::fs::remove_dir_all(&dir).ok();
        let r = Read {
            rows: session_table::rows(&state, &vocab, &session_table::Feed::default(), &[]),
            buckets: vocab.buckets().to_vec(),
            ..Read::default()
        };
        let v: serde_json::Value =
            serde_json::from_str(&render(&r, &TableQuery::default())).unwrap();
        assert_eq!(v["rows"][0]["project"], "trader");
        assert_eq!(v["buckets"], serde_json::json!(["NEEDS", "WORKING"]));
    }
}
