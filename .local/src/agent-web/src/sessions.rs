//! The Sessions tab's table and header, from hub-core's `session_table` and `capacity`. The rows
//! are filtered and sorted here by `hub_core::table`, so the page only draws.

use std::sync::Arc;
use std::time::{Duration, Instant};

use hub_core::boards;
use hub_core::capacity::{self, Capacity};
use hub_core::session_actions::{self as actions, System};
use hub_core::session_table::{self, SessionRow};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

/// Folds concurrent tabs, quick reloads and every keystroke in the search into one read.
const CACHE: Duration = Duration::from_secs(15);
/// `fleet-dispatch headroom` takes seconds on a loaded machine, and the state document it is
/// shown beside moves once a minute.
const CAPACITY_CACHE: Duration = Duration::from_secs(60);

/// The table view, the same keys the page keeps in its URL.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct TableQuery {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// Every row and what could not be read.
#[derive(Default)]
struct Read {
    rows: Vec<SessionRow>,
    errors: Vec<String>,
}

#[derive(Serialize)]
struct Shown<'a> {
    rows: Vec<&'a SessionRow>,
    errors: &'a [String],
    table: Summary,
}

#[derive(Default)]
pub struct Cache {
    table: Mutex<Option<(Instant, Arc<Read>)>>,
    capacity: Mutex<Option<(Instant, Arc<Capacity>)>>,
}

fn render(r: &Read, q: &TableQuery) -> String {
    let view = View::new::<SessionRow>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&r.rows);
    let out = Shown {
        rows,
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
    /// The view `q` asks for; every view is applied to the shared read outside the lock.
    pub async fn table(&self, q: TableQuery) -> String {
        let mut c = self.table.lock().await;
        let read = match c.as_ref().filter(|(at, _)| at.elapsed() < CACHE) {
            Some((_, r)) => Ok(r.clone()),
            None => tokio::task::spawn_blocking(|| {
                let state = session_table::read_state(&boards::fleet_state());
                let feed = session_table::feed(&System, &session_table::registry());
                Read {
                    rows: session_table::rows(&state, &feed, &actions::gather(&System).agents),
                    errors: feed.errors,
                }
            })
            .await
            .map(|r| {
                let r = Arc::new(r);
                *c = Some((Instant::now(), r.clone()));
                r
            })
            .map_err(|e| e.to_string()),
        };
        drop(c);
        read.map_or_else(failed, |r| render(&r, &q))
    }

    pub async fn capacity(&self) -> Result<Arc<Capacity>, String> {
        let mut c = self.capacity.lock().await;
        if let Some((_, got)) = c.as_ref().filter(|(at, _)| at.elapsed() < CAPACITY_CACHE) {
            return Ok(got.clone());
        }
        let got = tokio::task::spawn_blocking(|| capacity::read_fleet(&System))
            .await
            .map(Arc::new)
            .map_err(|e| e.to_string())?;
        *c = Some((Instant::now(), got.clone()));
        Ok(got)
    }

    /// Start a timer, and drop the header so the next read shows it on.
    pub async fn start(&self, name: String) -> Result<String, String> {
        let out = tokio::task::spawn_blocking(move || capacity::start(&System, &name))
            .await
            .map_err(|e| e.to_string())??;
        *self.capacity.lock().await = None;
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
            errors: vec!["session outcomes: exit 1".into()],
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
}
