//! Infra's CI runs section, and Releases' Release runs: CI runs of the last 30 days from hub-core's
//! `builds`, `scope=release` cutting them to the runs the graph tied to a release
//! (`Scope::Release`). The list is filtered and sorted here by `hub_core::table`, so the page
//! only draws. Its view keys carry a `b` prefix (`bq`, `bs`, `bsort`, `bdir`) because the table
//! beside it on either tab keeps the plain ones. A new ledger line pushes the `builds` event; a
//! run's log and its detail (jobs, steps, cost) are read when it is opened, priced with the rates
//! the Infra tab's answer carries.

use hub_core::builds::{self, Builds, Paths, Run, RunKey, Scope, STALE_SECS};
use hub_core::jobs::{self, now};
use hub_core::queue::Item;
use hub_core::run_detail::Rates;
use hub_core::session_actions::System;
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
    /// `release`: only the runs tied to a release (Releases' Release runs).
    pub scope: String,
}

/// The read with the view applied: the rows drawn, how many the cap left out, the controls.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    summary: String,
    stale_after: i64,
    rows: Vec<&'a Run>,
    more: usize,
    /// The scope's counts, whatever the view: Runners' `failed 24h` is `recent_red`.
    counts: &'a builds::Counts,
    errors: &'a [String],
    /// `Builds::needs_look`: the count on the inner tab the runs are on.
    look: bool,
    table: Summary,
}

fn render(b: &Builds, q: &Query) -> String {
    let scope = Scope::named(&q.scope);
    let s = b.scoped(scope);
    let view = View::new::<Run>(&q.bq, &q.bs, &q.bsort, &q.bdir);
    let (rows, mut table) = view.summary(&s.rows);
    let (rows, more) = builds::cap(rows.into_iter().copied().collect());
    // The links run beside the rows the page gets, and the cap dropped the rest.
    table.links = hub_core::table::links(&rows);
    let out = Shown {
        at: b.at,
        summary: s.summary(),
        stale_after: STALE_SECS,
        rows,
        more,
        counts: s.counts,
        errors: s.errors,
        look: b.needs_look(scope),
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the section can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

/// The ledger's read, joined to the PR store, the queue `items` and the releases, kept a few
/// seconds: the Tests section picks its runs from the same one.
pub async fn current(
    (items, queue_error): (Vec<Item>, Option<String>),
) -> Result<Arc<Builds>, String> {
    READ.get((), async {
        off(move || {
            let join = builds::Join {
                runner: &System,
                items: &items,
            };
            let mut b = builds::read(&Paths::from_env(), Some(join), now());
            b.errors.extend(queue_error);
            b
        })
        .await
    })
    .await
}

/// The view `q` asks for.
pub async fn get(q: Query, items: (Vec<Item>, Option<String>)) -> String {
    current(items).await.map_or_else(failed, |b| render(&b, &q))
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

/// The run `key` names, opened: header, jobs and steps from the ledger and the job archive.
/// Nothing is fetched; a run the archive does not hold says so in its coverage.
pub async fn detail(key: RunKey, rates: Rates) -> Result<String, String> {
    let d = off(move || builds::detail(&Paths::from_env(), &rates, &key, now())).await??;
    serde_json::to_string(&d).map_err(|e| e.to_string())
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
            ..Default::default()
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
        assert_eq!(v["counts"]["red"], 1, "the counts ride whatever the view");
        assert!(v.get("times").is_none(), "the Run times fold is retired");
    }

    #[test]
    fn the_release_scope_lists_only_the_runs_tied_to_a_release() {
        let mut b = sample();
        b.rows[2].release = Some(hub_core::release_graph::RunRelease {
            project: "app".into(),
            tag: "v1.0.0".into(),
        });
        // What the read counts the release scope with.
        b.released = builds::Counts {
            total: 1,
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(
            &b,
            &Query {
                scope: "release".into(),
                ..Default::default()
            },
        ))
        .unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["release"]["tag"], "v1.0.0");
        assert_eq!(v["summary"], "1 run in 30 days: 0 running, 0 queued, 0 red");
        assert_eq!(v["counts"]["total"], 1, "the scope's own counts");
        // negative control: the plain read keeps every run.
        assert_eq!(body(Query::default())["rows"].as_array().unwrap().len(), 3);
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
