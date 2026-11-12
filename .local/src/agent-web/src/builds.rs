//! Infra's CI runs section, and Releases' Release runs: CI runs of the last 30 days from hub-core's
//! `builds`, `scope=release` cutting them to the runs the graph tied to a release
//! (`Scope::Release`). The list is filtered and sorted here by `hub_core::table`, so the page
//! only draws. Its view keys carry a `b` prefix (`bq`, `bs`, `bsort`, `bdir`) because the table
//! beside it on either tab keeps the plain ones. A new ledger line pushes the `builds` event; a
//! run's log and its detail (jobs, steps, cost) are read when it is opened, priced with the rates
//! the Infra tab's answer carries.

use hub_core::builds::{self, Builds, Paths, Run, RunKey, Scope, STALE_SECS};
use hub_core::jobs::{self, now};
use hub_core::quarantine::{Lane, OwnerRow};
use hub_core::queue::Item;
use hub_core::releases::Level;
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
    /// Each workflow's usual run time: the Run times fold, whatever the view.
    times: &'a [builds::RunTime],
    errors: &'a [String],
    /// The Quarantine fold: a lane per repo whose base carries a quarantine, and its worst.
    quarantine: Vec<Quarantined<'a>>,
    quarantine_level: Level,
    /// `Builds::needs_look`: the count on the inner tab the runs are on.
    look: bool,
    table: Summary,
}

/// One repo's quarantine as the fold draws it: its line and colour, then each owner row's.
#[derive(Serialize)]
struct Quarantined<'a> {
    repo: &'a str,
    says: String,
    level: Level,
    entries: u64,
    /// The nightly the counts came from.
    url: Option<&'a str>,
    rows: Vec<Owned<'a>>,
}

#[derive(Serialize)]
struct Owned<'a> {
    #[serde(flatten)]
    row: &'a OwnerRow,
    level: Level,
    left: String,
}

fn quarantined(l: &Lane) -> Quarantined<'_> {
    Quarantined {
        repo: &l.repo,
        says: l.says(),
        level: l.level(),
        entries: l.report.as_ref().map_or(0, |r| r.entries),
        url: l.nightly.as_ref().and_then(|n| n.url.as_deref()),
        rows: l
            .rows()
            .iter()
            .map(|row| Owned {
                row,
                level: row.level(),
                left: row.left(),
            })
            .collect(),
    }
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
        times: s.times,
        errors: s.errors,
        quarantine: s.quarantine.iter().map(quarantined).collect(),
        quarantine_level: s
            .quarantine
            .iter()
            .map(Lane::level)
            .min()
            .unwrap_or_default(),
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
            times: vec![builds::RunTime {
                repo: "Org/app".into(),
                workflow: "Tests".into(),
                runs: 3,
                ..Default::default()
            }],
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
        assert_eq!(
            v["times"][0]["workflow"], "Tests",
            "the Run times fold rides the same read"
        );
        assert!(
            v.get("costs").is_none(),
            "the Run times fold carries no money"
        );
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
        assert!(v["times"].as_array().unwrap().is_empty());
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
    fn each_quarantine_lane_carries_its_line_colour_and_owner_rows() {
        use hub_core::quarantine::{Nightly, Report};
        let b = Builds {
            quarantine: vec![Lane {
                repo: "Org/play".into(),
                report: Some(Report {
                    entries: 3,
                    rows: vec![OwnerRow {
                        row: "ucp-1".into(),
                        entries: 3,
                        ends: "2026-11-12".into(),
                        days_left: 1,
                    }],
                }),
                nightly: Some(Nightly {
                    url: Some("https://x/runs/9".into()),
                    known: 2,
                    now_passing: Some(1),
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&b, &Query::default())).unwrap();
        let q = &v["quarantine"][0];
        assert_eq!(q["level"], "warn");
        assert_eq!(q["url"], "https://x/runs/9");
        assert!(q["says"]
            .as_str()
            .unwrap()
            .contains("2 known red, 1 now pass"));
        assert_eq!(q["rows"][0]["row"], "ucp-1");
        assert_eq!(q["rows"][0]["days_left"], 1);
        assert_eq!(q["rows"][0]["level"], "warn");
        assert_eq!(q["rows"][0]["left"], "1d");
        assert_eq!(q["entries"], 3);
        assert_eq!(v["quarantine_level"], "warn");
    }

    #[test]
    fn a_failed_read_still_gives_the_section_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
