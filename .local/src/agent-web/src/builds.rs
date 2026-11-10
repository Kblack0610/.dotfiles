//! The Releases tab's Builds section: CI runs of the last 30 days from hub-core's `builds`. The
//! list is filtered and sorted here by `hub_core::table`, so the page only draws. Its view keys
//! carry a `b` prefix (`bq`, `bs`, `bsort`, `bdir`) because the channels table above it keeps the
//! plain ones. A new ledger line pushes the `builds` event; a run's log is read when it is opened.

use hub_core::builds::{self, Builds, Paths, Run, RunKey, STALE_SECS};
use hub_core::jobs::{self, now};
use hub_core::table::{Summary, View};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::cache::{off, ReadCache};

/// Quick reloads and each keystroke in the search share one read of a 7 MB ledger.
const CACHE_SECS: u64 = 5;
static READ: ReadCache<Builds, CACHE_SECS> = ReadCache::new();

/// The table view, under the section's own key prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub bq: String,
    pub bs: String,
    pub bsort: String,
    pub bdir: String,
}

/// The read with the view applied: the rows drawn, how many the cap left out, the controls.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    summary: String,
    stale_after: i64,
    rows: Vec<&'a Run>,
    more: usize,
    errors: &'a [String],
    table: Summary,
}

fn render(b: &Builds, q: &Query) -> String {
    let view = View::new::<Run>(&q.bq, &q.bs, &q.bsort, &q.bdir);
    let (rows, table) = view.summary(&b.rows);
    let (rows, more) = builds::cap(rows);
    let out = Shown {
        at: b.at,
        summary: b.summary(),
        stale_after: STALE_SECS,
        rows,
        more,
        errors: &b.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the section can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

/// The ledger's read, kept a few seconds: the Tests section picks its runs from the same one.
pub async fn current() -> Result<Arc<Builds>, String> {
    READ.get((), async {
        off(|| builds::read(&Paths::from_env(), now())).await
    })
    .await
}

/// The view `q` asks for.
pub async fn get(q: Query) -> String {
    current().await.map_or_else(failed, |b| render(&b, &q))
}

/// Drop the kept read, so the page's refetch after a ledger append sees the append.
pub async fn forget() {
    READ.clear().await;
}

/// The log tail of the run `key` names. The outer error is a request that names no run; the
/// inner one, a log that could not be fetched.
pub async fn log(key: RunKey) -> Result<String, String> {
    off(move || builds::log(&Paths::from_env(), &jobs::Paths::from_env(), &key, now()))
        .await
        .and_then(|r| r)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(id: u64, state: &str) -> Run {
        Run {
            id,
            repo: "Org/app".into(),
            state: state.into(),
            ..Default::default()
        }
    }

    fn sample() -> Builds {
        let rows = vec![run(1, "running"), run(2, "red"), run(3, "green")];
        Builds {
            at: 300,
            counts: builds::Counts {
                total: 3,
                running: 1,
                queued: 0,
                red: 1,
                ..Default::default()
            },
            rows,
            errors: vec![],
        }
    }

    fn body(q: Query) -> serde_json::Value {
        serde_json::from_str(&render(&sample(), &q)).unwrap()
    }

    #[test]
    fn the_plain_view_lists_every_run_and_says_how_they_divide() {
        let v = body(Query::default());
        assert_eq!(v["rows"].as_array().unwrap().len(), 3);
        assert_eq!(v["more"], 0);
        assert_eq!(v["table"]["total"], 3);
        assert_eq!(
            v["summary"],
            "3 runs in 30 days: 1 running, 0 queued, 1 red"
        );
        assert_eq!(v["stale_after"], STALE_SECS);
    }

    #[test]
    fn a_chip_keeps_its_state_and_the_total_still_counts_every_run() {
        let v = body(Query {
            bs: "red".into(),
            ..Default::default()
        });
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["id"], 2);
        assert_eq!(v["table"]["total"], 3);
    }

    #[test]
    fn the_cap_leaves_the_rest_one_search_away() {
        let b = Builds {
            rows: (0..builds::LIST_ROWS as u64 + 5)
                .map(|i| run(i, "green"))
                .collect(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&b, &Query::default())).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), builds::LIST_ROWS);
        assert_eq!(v["more"], 5);
    }

    #[test]
    fn a_failed_read_still_gives_the_section_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
