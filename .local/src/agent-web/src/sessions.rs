//! The Sessions tab's table and header, from hub-core's `session_table` and `capacity`. The rows
//! are filtered and sorted here by `hub_core::table`, so the page only draws.

use std::sync::Arc;

use hub_core::boards;
use hub_core::capacity::{self, Capacity};
use hub_core::layout;
use hub_core::session_actions::System;
use hub_core::session_page::{self, SessionPage};
use hub_core::session_table::{self, SessionRow};
use hub_core::table::{self, Summary, View};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cache::{off, ReadCache};
use crate::Shared;

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
    pub pg: String,
    /// The open session (its target or session id): with no `pg`, the page that holds it, so the
    /// split view's list shows the row it marks.
    pub sel: String,
}

/// Every row, the state document under it and what could not be read.
#[derive(Default)]
pub(crate) struct Read {
    pub(crate) rows: Vec<SessionRow>,
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
}

pub struct Cache {
    table: ReadCache<Read, CACHE_SECS>,
    /// The last page opened, by its id.
    page: ReadCache<Option<SessionPage>, CACHE_SECS, String>,
    capacity: ReadCache<Capacity, CAPACITY_SECS>,
}

impl Default for Cache {
    fn default() -> Self {
        Self {
            table: ReadCache::new("session-table"),
            page: ReadCache::new("session-page"),
            capacity: ReadCache::new("session-capacity"),
        }
    }
}

/// One page of the rows the view keeps (`layout`'s `sessions` size).
fn render(r: &Read, q: &TableQuery) -> String {
    let view = View::new::<SessionRow>(&q.q, &q.s, &q.sort, &q.dir);
    let (mut rows, mut table) = view.summary(&r.rows);
    let per = layout::page_rows("sessions/sessions");
    let page = q.pg.parse().unwrap_or_else(|_| {
        let at = rows.iter().position(|r| {
            !q.sel.is_empty() && (r.key == q.sel || r.target == q.sel || r.session_id == q.sel)
        });
        at.map_or(1, |at| at / per + 1)
    });
    table::page(&mut rows, &mut table, page, per);
    let out = Shown {
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
    /// The table's rows: the sessions are the sidebar's read (`live.rs`) and the queue items are
    /// the Queue tab's (`queue::Cache`), so this runs neither `collect_all` nor `agent-queue`.
    pub(crate) async fn read(&self, s: &Shared) -> Result<Arc<Read>, String> {
        // Fetched inside the kept read, so a table that is fresh touches neither source.
        let s = s.clone();
        let read = async move {
            let (live, queue) =
                tokio::join!(s.live.get((), crate::read_live), s.queue.feed_items());
            let live = live?;
            off(move || {
                let (state, vocab, silent) = session_table::read_state(&boards::fleet_state());
                let active = queue
                    .as_deref()
                    .map(hub_core::queue::active)
                    .unwrap_or_default();
                let agents: Vec<_> = live
                    .rows
                    .iter()
                    .map(|r| r.agent.clone())
                    .zip(live.joined(&active))
                    .collect();
                let feed = session_table::feed_with(&System, &session_table::registry(), queue);
                Read {
                    rows: session_table::rows(&state, &vocab, &feed, &agents),
                    state,
                    buckets: vocab.buckets().to_vec(),
                    errors: feed.errors.into_iter().chain(silent).collect(),
                }
            })
            .await
        };
        self.table.get((), read).await
    }

    /// The view `q` asks for; every view is applied to the shared read outside the lock.
    pub async fn table(&self, s: &Shared, q: TableQuery) -> String {
        self.read(s).await.map_or_else(failed, |r| render(&r, &q))
    }

    /// One session's page, or None when nothing names `id`. The open page refreshes with the
    /// list, so the last one is kept as the list's read is; a None is not kept.
    pub async fn page(&self, s: &Shared, id: String) -> Result<Arc<Option<SessionPage>>, String> {
        let key = id.clone();
        let table = self.read(s).await?;
        let read = off(move || {
            session_page::read(
                &System,
                &boards::shepherd_dir(),
                &id,
                &table.rows,
                &table.state,
                &session_table::registry(),
            )
        });
        self.page.get_if(key, read, Option::is_some).await
    }

    pub async fn capacity(&self) -> Result<Arc<Capacity>, String> {
        let read = off(|| capacity::read_fleet(&System));
        self.capacity.get((), read).await
    }

    /// Start a timer, and drop the header so the next read shows it on.
    pub async fn start(&self, name: String) -> Result<String, String> {
        let out = off(move || capacity::start(&System, &name)).await??;
        self.capacity.clear();
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
            done: source == Source::Queue,
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
            s: "ended today".into(),
            ..TableQuery::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&r, &q)).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["key"], "slug");
        assert_eq!(v["rows"][0]["source"], "queue");
        assert_eq!(v["errors"][0], "session outcomes: exit 1");
        assert_eq!(v["table"]["state"], "ended today");
        assert_eq!(v["table"]["total"], 2);
        assert!(v["table"].get("pager").is_none(), "one page is unpaged");
    }

    #[test]
    fn the_table_pages_at_its_layout_size_and_the_spend_is_every_pages() {
        let per = layout::page_rows("sessions/sessions");
        let r = Read {
            rows: (0..per + 3)
                .map(|i| SessionRow {
                    key: format!("k{i}"),
                    cost_usd: Some(1.0),
                    ..SessionRow::default()
                })
                .collect(),
            ..Read::default()
        };
        let q = TableQuery {
            pg: "2".into(),
            ..TableQuery::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&r, &q)).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 3);
        assert_eq!(v["rows"][0]["key"], format!("k{per}"));
        assert_eq!(v["table"]["pager"]["page"], 2);
        assert_eq!(v["table"]["shown"], per + 3);
        let sel = |sel: &str, pg: &str| TableQuery {
            sel: sel.into(),
            pg: pg.into(),
            ..TableQuery::default()
        };
        let page = |q: &TableQuery| -> serde_json::Value {
            serde_json::from_str::<serde_json::Value>(&render(&r, q)).unwrap()["table"]["pager"]
                ["page"]
                .clone()
        };
        let tail = format!("k{}", per + 1);
        assert_eq!(page(&sel(&tail, "")), 2, "the open session's page");
        assert_eq!(page(&sel(&tail, "1")), 1, "a page asked for wins");
        assert_eq!(page(&sel("gone", "")), 1);
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
        let (state, vocab, _) = session_table::read_state(&path);
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
