//! Infra's CI Tests section: one block (lane) per declared test workflow (`testWorkflows` in the
//! registry) of one repo, each with the suites of one finished run from hub-core's `junit`, and
//! the Quarantine table, one row per quarantined test of every repo, from hub-core's
//! `quarantine`. A lane's run is its default (`junit::lanes`: the latest nightly, else its newest
//! finished run) unless `trun` names one of its runs; `trun` is a comma list of run ids, one per
//! lane at most, so a pick in one lane leaves the others on their defaults. The repo is the one
//! the page names (`trepo`), else the repo of a run `trun` names, else the repo of the newest
//! finished run; a declared workflow with no finished run still has its lane, with a note and no
//! run. `repos` lists the repos a picker can switch to. Each run's artifacts are fetched when it
//! is first read and kept in a slot of its lane, so only the first look at a run waits on GitHub
//! and a pick in one lane never evicts another's. A failure of a test the run's repo holds in
//! quarantine counts as quarantined, applied on each read so a quarantine change shows without a
//! re-fetch. The suites are filtered and sorted here by `hub_core::table`, so the page only
//! draws, a page at a time: one view (`tq`, `ts`, `tsort`, `tdir`, `tpg`) applies to every lane,
//! the top `table` is the bar's summary over all of them and each lane's `table` its own columns,
//! counts and pager. The Quarantine's keys carry a `q` (`qq`, `qs`, `qsort`, `qdir`, `qpg`). An
//! opened suite reads its tests from `/api/tests/cases`, which uses the same kept read; their view
//! keys carry a `c` (`cq`, `cs`, `csort`, `cdir`, `cpg`). The quarantine rides the builds read, so
//! its file's change pushes the `builds` event the section already listens to.

use std::sync::Arc;

use axum::http::StatusCode;
use hub_core::builds::{Builds, STALE_SECS};
use hub_core::jobs;
use hub_core::junit::{self, Case, Loaded, PickRun, Suite, Totals};
use hub_core::layout;
use hub_core::quarantine::{self, Entry};
use hub_core::queue::Item;
use hub_core::releases::Level;
use hub_core::run_page::applied;
use hub_core::session_actions::System;
use hub_core::table::{self, Summary, View};
use serde::{Deserialize, Serialize};

use crate::builds;
use crate::cache::{failed, off, ReadCache};

/// The table view, under the section's own key prefix, and the run to show (a run id).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub tq: String,
    pub ts: String,
    pub tsort: String,
    pub tdir: String,
    pub tpg: String,
    pub trun: String,
    /// The repo whose runs the picker offers: its slug or project name.
    pub trepo: String,
    pub qq: String,
    pub qs: String,
    pub qsort: String,
    pub qdir: String,
    pub qpg: String,
}

/// An opened suite: its tier and file name, and its tests' view under the `c` prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CasesQuery {
    pub run: u64,
    pub tier: String,
    pub suite: String,
    pub cq: String,
    pub cs: String,
    pub csort: String,
    pub cdir: String,
    pub cpg: String,
}

#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    stale_after: i64,
    /// The repos with runs to pick from, the one with the newest run first.
    repos: Vec<&'a str>,
    /// The repo whose lanes `lanes` are.
    repo: Option<&'a str>,
    /// What every lane's suites add up to.
    totals: Totals,
    /// One block per declared workflow of the repo, in the order the registry declares them.
    lanes: Vec<serde_json::Value>,
    /// Why a repo or run asked for was not shown.
    errors: Vec<String>,
    /// The view over every lane's suites: the bar's chips, facets and search; each lane's own
    /// `table` carries its columns, counts and pager.
    table: Summary,
    quarantine: Held<'a>,
}

/// One lane of the page: a declared test workflow, the run shown of it and that run's suites.
#[derive(Serialize)]
struct LaneShown<'a> {
    workflow: &'a str,
    /// The run shown: `trun`'s pick for this lane, else its default.
    run: Option<&'a PickRun>,
    /// `trun` named the run shown, so the picker keeps it when another lane's pick changes.
    pinned: bool,
    /// The lane's finished runs, newest first, for its picker.
    runs: &'a [&'a PickRun],
    /// `totals` in words, hub-core's `Totals::says`.
    says: String,
    totals: Totals,
    rows: Vec<&'a Suite>,
    fold: Option<String>,
    /// Why there is nothing to list when that is not a fault: no finished run, no artifacts.
    note: Option<String>,
    errors: Vec<String>,
    table: Summary,
}

/// The Quarantine table: each lane's line over one row per quarantined test.
#[derive(Serialize)]
struct Held<'a> {
    lanes: Vec<HeldLane<'a>>,
    rows: Vec<&'a Entry>,
    /// Why quarantine.json did not parse: the table's red line.
    error: Option<&'a str>,
    table: Summary,
}

#[derive(Serialize)]
struct HeldLane<'a> {
    repo: String,
    says: String,
    level: Level,
    /// The nightly the counts came from.
    url: Option<&'a str>,
}

fn held<'a>(b: &'a Builds, entries: &'a [Entry], q: &Query) -> Held<'a> {
    let view = View::new::<Entry>(&q.qq, &q.qs, &q.qsort, &q.qdir);
    let (mut rows, mut table) = view.summary(entries);
    let page = q.qpg.parse().unwrap_or(1);
    table::page(&mut rows, &mut table, page, layout::page_rows("quarantine"));
    Held {
        lanes: b
            .quarantine
            .iter()
            .map(|l| HeldLane {
                repo: project_map::canonical(&l.repo),
                says: l.says(),
                level: l.level(),
                url: l.url(),
            })
            .collect(),
        rows,
        error: b.quarantine_error.as_deref(),
        table,
    }
}

/// One lane and what reading its run produced.
struct LaneRead<'a> {
    workflow: &'a str,
    runs: &'a [&'a PickRun],
    run: Option<&'a PickRun>,
    /// `trun` named this run, so a pick in another lane keeps it.
    pinned: bool,
    loaded: Option<Arc<Loaded>>,
    errors: Vec<String>,
}

/// What a read of the ledger and each lane's run produced.
struct Read<'a> {
    builds: &'a Builds,
    runs: &'a [PickRun],
    repo: Option<&'a str>,
    lanes: Vec<LaneRead<'a>>,
    errors: Vec<String>,
}

fn render(r: &Read, q: &Query) -> String {
    let view = View::new::<Suite>(&q.tq, &q.ts, &q.tsort, &q.tdir);
    let page = q.tpg.parse().unwrap_or(1);
    let mut union: Vec<Suite> = vec![];
    let mut lanes = vec![];
    for l in &r.lanes {
        let applied = match (l.run, &l.loaded) {
            (Some(run), Some(ld)) => Some(applied(r.builds, &run.repo, ld)),
            _ => None,
        };
        let suites: &[Suite] = applied.as_ref().map_or(&[], |a| &a.suites);
        // the union is only counted, never drawn: a suite's tests stay with its lane
        union.extend(suites.iter().map(Suite::counts_only));
        let (rows, mut table) = view.summary(suites);
        let totals = junit::totals(suites);
        let (mut rows, fold) = junit::fold(&view, rows, &totals);
        table::page(&mut rows, &mut table, page, layout::page_rows("tests"));
        // the bar draws the facets once, over every lane
        table.facets.clear();
        let mut errors = l.errors.clone();
        errors.extend(l.loaded.iter().flat_map(|a| a.errors.clone()));
        let note = match (l.run, &l.loaded) {
            (None, _) => Some(format!(
                "{}: no finished run in the ledger (a cancelled or skipped run is not listed)",
                l.workflow
            )),
            (_, loaded) => loaded.as_ref().and_then(|a| a.note.clone()),
        };
        let shown = LaneShown {
            workflow: l.workflow,
            run: l.run,
            pinned: l.pinned,
            runs: l.runs,
            says: totals.says(),
            totals,
            rows,
            fold,
            note,
            errors,
            table,
        };
        lanes.push(serde_json::to_value(&shown).unwrap_or_default());
    }
    let (_, table) = view.summary(&union);
    let entries = quarantine::entries(&r.builds.quarantine);
    let out = Shown {
        at: r.builds.at,
        stale_after: STALE_SECS,
        repos: junit::repos(r.runs),
        repo: r.repo,
        totals: junit::totals(&union),
        lanes,
        errors: r.errors.clone(),
        table,
        quarantine: held(r.builds, &entries, q),
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(&["lanes", "repos"], e.to_string()))
}

/// The repo whose lanes the page draws: the one `repo` names (its slug or project name), else
/// the repo of the first run `ids` names, else the repo of the newest run. The second value says
/// when the repo asked for has no runs.
fn choose_repo<'a>(
    runs: &'a [PickRun],
    repo: &str,
    ids: &[u64],
) -> (Option<&'a str>, Option<String>) {
    let mine = |r: &&PickRun| {
        r.repo.eq_ignore_ascii_case(repo)
            || project_map::canonical(&r.repo).eq_ignore_ascii_case(repo)
    };
    if !repo.is_empty() {
        if let Some(r) = runs.iter().find(mine) {
            return (Some(&r.repo), None);
        }
    }
    let asked = ids.iter().find_map(|w| runs.iter().find(|r| r.id == *w));
    if let Some(r) = asked {
        return (Some(&r.repo), None);
    }
    let why = (!repo.is_empty() && !runs.is_empty())
        .then(|| format!("{repo} has no finished test runs; showing the newest"));
    (runs.first().map(|r| r.repo.as_str()), why)
}

/// The run ids `trun` names: comma separated, one per lane at most.
fn run_ids(trun: &str) -> Vec<u64> {
    trun.split(',')
        .filter_map(|i| i.trim().parse().ok())
        .collect()
}

/// One entry per declared workflow of `repo`, in `declared` order (a lane the ledger has runs
/// for but the registry no longer declares follows): the run `ids` names in it, else its default
/// (`junit::lanes`: the latest nightly, else the newest). A declared workflow with no finished run
/// stays, with no run. The second value says which run asked for is in none of them.
fn choose_lanes<'l, 'p>(
    lanes: &'l [junit::Lane<'p>],
    declared: &'l [String],
    ids: &[u64],
) -> (Vec<(&'l str, Option<&'l junit::Lane<'p>>)>, Option<String>) {
    let mut out: Vec<(&str, Option<&junit::Lane>)> = declared
        .iter()
        .map(|w| (w.as_str(), lanes.iter().find(|l| l.workflow == w)))
        .collect();
    for l in lanes {
        if !declared.iter().any(|w| w == l.workflow) {
            out.push((l.workflow, Some(l)));
        }
    }
    let lost: Vec<String> = ids
        .iter()
        .filter(|id| !lanes.iter().any(|l| l.runs.iter().any(|r| r.id == **id)))
        .map(u64::to_string)
        .collect();
    let why = (!lost.is_empty()).then(|| {
        format!(
            "run {} {} not among the last {} finished runs of its repo; showing the default",
            lost.join(", "),
            if lost.len() == 1 { "is" } else { "are" },
            junit::PICK_RUNS
        )
    });
    (out, why)
}

/// The run `lane` shows: the one `ids` names in it, else its default.
fn shown_run<'p>(lane: &junit::Lane<'p>, ids: &[u64]) -> &'p PickRun {
    ids.iter()
        .find_map(|id| lane.runs.iter().find(|r| r.id == *id).copied())
        .unwrap_or(lane.default)
}

/// Kept reads of the finished runs. Each lane (its workflow's place among the repo's declared
/// ones) has a slot for the run it opens on, which `keep_newest` fills, and a slot for the run a
/// visitor picks, so browsing older runs never evicts a default another visitor opens on, nor
/// another lane's results, nor waits behind their download. A project with more lanes than slots
/// shares the last; a lane of another repo shares its rank's slot, so a visit there evicts that
/// rank's default until the next warm.
const LANE_SLOTS: usize = 8;
/// A finished run's results never change; this only bounds how long a stale `Loaded` (a failed
/// report fixed by a re-fetch) could be kept.
const CACHE_SECS: u64 = 600;
static NEWEST: [ReadCache<Loaded, CACHE_SECS, (u64, u32)>; LANE_SLOTS] =
    [const { ReadCache::new("suites-newest") }; LANE_SLOTS];
static PICKED: [ReadCache<Loaded, CACHE_SECS, (u64, u32)>; LANE_SLOTS] =
    [const { ReadCache::new("suites") }; LANE_SLOTS];

/// One run's results, kept once read, in its lane's default slot when it is the lane's default,
/// else in the lane's picked slot. Fetching blocks on `gh`, so it runs off the async threads.
async fn loaded(run: &PickRun, default: bool) -> Result<Arc<Loaded>, String> {
    let r = run.clone();
    let slots = if default { &NEWEST } else { &PICKED };
    slots[run.rank.min(LANE_SLOTS - 1)]
        .get((run.id, run.attempt), async move {
            off(move || junit::load(&jobs::Paths::from_env().cache, &r, &System))
                .await
                .and_then(|l| l)
        })
        .await
}

/// Read the run each lane of the default repo opens on into the kept reads, so the first visitor
/// after a run lands is not the one who waits on its `gh` download. Nothing is shown and a
/// failure is not kept: the tab reads again and shows it.
pub async fn keep_newest(items: (Vec<Item>, Option<String>)) {
    let Ok(b) = builds::current(items).await else {
        return;
    };
    let runs = junit::pickable(&b, project_map::cached().as_deref());
    let (repo, _) = choose_repo(&runs, "", &[]);
    let in_repo: Vec<PickRun> = runs
        .iter()
        .filter(|r| Some(r.repo.as_str()) == repo)
        .cloned()
        .collect();
    for lane in junit::lanes(&in_repo) {
        if let Err(e) = loaded(lane.default, true).await {
            eprintln!(
                "agent-web: tests read of run {} failed: {e}",
                lane.default.id
            );
        }
    }
}

/// The view `q` asks for.
pub async fn get(q: Query, items: (Vec<Item>, Option<String>)) -> String {
    let b = match builds::current(items).await {
        Ok(b) => b,
        Err(e) => return failed(&["lanes", "repos"], e),
    };
    let registry = project_map::cached();
    let runs = junit::pickable(&b, registry.as_deref());
    let ids = run_ids(&q.trun);
    let (repo, why) = choose_repo(&runs, &q.trepo, &ids);
    let in_repo: Vec<PickRun> = runs
        .iter()
        .filter(|r| Some(r.repo.as_str()) == repo)
        .cloned()
        .collect();
    let lanes = junit::lanes(&in_repo);
    let declared = match (repo, &registry) {
        (Some(r), Some(reg)) => reg.test_workflows(r),
        _ => vec![],
    };
    let (chosen, lost) = choose_lanes(&lanes, &declared, &ids);
    let mut read = vec![];
    for (workflow, lane) in chosen {
        let run = lane.map(|l| shown_run(l, &ids));
        let default = lane.is_some_and(|l| run.is_some_and(|r| r.id == l.default.id));
        let (kept, errors) = match run {
            Some(run) => match loaded(run, default).await {
                Ok(l) => (Some(l), vec![]),
                Err(e) => (None, vec![e]),
            },
            None => (None, vec![]),
        };
        read.push(LaneRead {
            workflow,
            runs: lane.map_or(&[], |l| l.runs.as_slice()),
            run,
            pinned: run.is_some_and(|r| ids.contains(&r.id)),
            loaded: kept,
            errors,
        });
    }
    render(
        &Read {
            builds: &b,
            runs: &runs,
            repo,
            lanes: read,
            errors: why.into_iter().chain(lost).collect(),
        },
        &q,
    )
}

#[derive(Serialize)]
struct CaseList<'a> {
    cases: Vec<&'a Case>,
    table: Summary,
}

/// Page `q.cpg` of the tests of the suite `q` names in run `q.run` its view keeps, failed first,
/// with the summary over all of them; they page as the suites do. A request that names no run or
/// suite is a 404; a failed read of the ledger or of GitHub is a 502. It never supplies a path
/// or a URL.
pub async fn cases(
    q: CasesQuery,
    items: (Vec<Item>, Option<String>),
) -> Result<String, (StatusCode, String)> {
    let bad = |e: String| (StatusCode::BAD_GATEWAY, e);
    let none = |e: &str| (StatusCode::NOT_FOUND, e.to_string());
    let b = builds::current(items).await.map_err(bad)?;
    let runs = junit::pickable(&b, project_map::cached().as_deref());
    let run = runs.iter().find(|r| r.id == q.run).ok_or_else(|| {
        none("that run is not among the finished runs of a declared test workflow")
    })?;
    let in_repo: Vec<PickRun> = runs
        .iter()
        .filter(|r| r.repo == run.repo)
        .cloned()
        .collect();
    let default = junit::lanes(&in_repo)
        .iter()
        .any(|l| l.default.id == run.id);
    let l = applied(&b, &run.repo, &*loaded(run, default).await.map_err(bad)?);
    let view = View::new::<Case>(&q.cq, &q.cs, &q.csort, &q.cdir);
    let (mut cases, mut table) = l
        .cases(&q.tier, &q.suite, &view)
        .ok_or_else(|| none("that suite is not in the run's results"))?;
    let page = q.cpg.parse().unwrap_or(1);
    table::page(&mut cases, &mut table, page, layout::page_rows("tests"));
    serde_json::to_string(&CaseList { cases, table }).map_err(|e| bad(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::quarantine::Lane;

    fn suite(tier: &str, name: &str, results: &[&str]) -> Suite {
        let cases = results
            .iter()
            .enumerate()
            .map(|(i, r)| Case {
                name: format!("test {i}"),
                result: r.to_string(),
                ..Default::default()
            })
            .collect();
        Suite::new(tier, name, cases)
    }

    fn pick(id: u64) -> PickRun {
        PickRun {
            repo: "Org/app".into(),
            id,
            attempt: 1,
            branch: "main".into(),
            sha: "abc1234".into(),
            title: String::new(),
            state: "green".into(),
            level: Default::default(),
            started: 0,
            prs: vec![],
            url: String::new(),
            path: String::new(),
            event: String::new(),
            rank: 0,
            artifacts: vec![],
            store: None,
        }
    }

    /// `get` without the reads: the page for `runs`, the repo and runs asked for, and the
    /// workflows the registry declares, each lane's results from `load`.
    fn page(
        b: &Builds,
        runs: &[PickRun],
        (repo_q, trun): (&str, &str),
        declared: &[&str],
        load: impl Fn(&PickRun) -> Option<Loaded>,
        q: &Query,
    ) -> serde_json::Value {
        let ids = run_ids(trun);
        let (repo, why) = choose_repo(runs, repo_q, &ids);
        let in_repo: Vec<PickRun> = runs
            .iter()
            .filter(|r| Some(r.repo.as_str()) == repo)
            .cloned()
            .collect();
        let lanes = junit::lanes(&in_repo);
        let declared: Vec<String> = declared.iter().map(|d| d.to_string()).collect();
        let (chosen, lost) = choose_lanes(&lanes, &declared, &ids);
        let read = chosen
            .into_iter()
            .map(|(workflow, lane)| {
                let run = lane.map(|l| shown_run(l, &ids));
                LaneRead {
                    workflow,
                    runs: lane.map_or(&[], |l| l.runs.as_slice()),
                    run,
                    pinned: run.is_some_and(|r| ids.contains(&r.id)),
                    loaded: run.and_then(&load).map(Arc::new),
                    errors: vec![],
                }
            })
            .collect();
        let r = Read {
            builds: b,
            runs,
            repo,
            lanes: read,
            errors: why.into_iter().chain(lost).collect(),
        };
        serde_json::from_str(&render(&r, q)).unwrap()
    }

    fn body(l: Option<&Loaded>, q: Query) -> serde_json::Value {
        let b = Builds {
            at: 300,
            ..Default::default()
        };
        page(&b, &[pick(7), pick(6)], ("", ""), &[], |_| l.cloned(), &q)
    }

    /// The first lane of a page: the one most tests read.
    fn lane(v: &serde_json::Value) -> &serde_json::Value {
        &v["lanes"][0]
    }

    fn red() -> Loaded {
        Loaded {
            suites: vec![
                suite("unit", "a.bats", &["passed", "failed"]),
                suite("unit", "b.bats", &["passed"]),
                suite("ui", "c.bats", &["passed", "skipped"]),
            ],
            ..Default::default()
        }
    }

    #[test]
    fn the_plain_view_lists_every_suite_and_says_what_the_run_found() {
        let v = body(Some(&red()), Query::default());
        assert_eq!(lane(&v)["rows"].as_array().unwrap().len(), 3);
        assert_eq!(lane(&v)["fold"], serde_json::Value::Null);
        assert_eq!(lane(&v)["totals"]["failed_suites"], 1);
        assert_eq!(v["totals"]["failed_suites"], 1);
        assert_eq!(lane(&v)["runs"].as_array().unwrap().len(), 2);
        assert_eq!(v["stale_after"], STALE_SECS);
    }

    #[test]
    fn a_chip_and_the_tier_filter_keep_the_totals_of_the_whole_run() {
        let v = body(
            Some(&red()),
            Query {
                ts: "failed".into(),
                ..Default::default()
            },
        );
        assert_eq!(lane(&v)["rows"].as_array().unwrap().len(), 1);
        assert_eq!(lane(&v)["rows"][0]["suite"], "a.bats");
        assert_eq!(lane(&v)["table"]["total"], 3);
        let v = body(
            Some(&red()),
            Query {
                tq: "tier:ui".into(),
                ..Default::default()
            },
        );
        assert_eq!(lane(&v)["rows"][0]["suite"], "c.bats");
        assert_eq!(v["table"]["facets"][0]["key"], "tier");
        assert!(
            lane(&v)["table"]["facets"].as_array().unwrap().is_empty(),
            "the bar draws the facets once"
        );
        assert_eq!(
            v["table"]["facets"][0]["values"].as_array().unwrap().len(),
            2
        );
    }

    #[test]
    fn a_green_run_folds_to_one_line_until_a_chip_asks_for_the_rows() {
        let green = Loaded {
            suites: vec![suite("unit", "a.bats", &["passed"])],
            ..Default::default()
        };
        let v = body(Some(&green), Query::default());
        assert!(lane(&v)["rows"].as_array().unwrap().is_empty());
        assert_eq!(
            lane(&v)["fold"],
            "All green: 1 test in 1 suite: 0 failed, 0 skipped, 1 passed"
        );
        let v = body(
            Some(&green),
            Query {
                ts: "passed".into(),
                ..Default::default()
            },
        );
        assert_eq!(lane(&v)["rows"].as_array().unwrap().len(), 1);
        assert_eq!(lane(&v)["fold"], serde_json::Value::Null);
    }

    #[test]
    fn a_long_run_pages_at_the_tests_size_and_tpg_picks_the_page() {
        let per = layout::page_rows("tests");
        let l = Loaded {
            suites: (0..per + 5)
                .map(|i| suite("unit", &format!("s{i}.bats"), &["failed"]))
                .collect(),
            ..Default::default()
        };
        let v = body(Some(&l), Query::default());
        assert_eq!(lane(&v)["rows"].as_array().unwrap().len(), per);
        assert_eq!(lane(&v)["table"]["pager"]["pages"], 2);
        assert_eq!(
            lane(&v)["table"]["shown"],
            per + 5,
            "the summary counts every page"
        );
        let v = body(
            Some(&l),
            Query {
                tpg: "2".into(),
                ..Default::default()
            },
        );
        assert_eq!(lane(&v)["rows"].as_array().unwrap().len(), 5);
        assert_eq!(lane(&v)["table"]["pager"]["page"], 2);
        assert!(v.get("more").is_none());
        // negative control: a run that fits on one page sends no pager.
        let v = body(Some(&red()), Query::default());
        assert!(lane(&v)["table"].get("pager").is_none());
    }

    #[test]
    fn a_run_without_results_says_why_and_no_run_says_so() {
        let none = Loaded {
            note: Some("no artifacts".into()),
            ..Default::default()
        };
        let v = body(Some(&none), Query::default());
        assert_eq!(lane(&v)["note"], "no artifacts");
        let b = Builds::default();
        let v = page(&b, &[], ("", ""), &[], |_| None, &Query::default());
        assert!(v["lanes"].as_array().unwrap().is_empty());
        assert_eq!(v["table"]["total"], 0);
    }

    fn in_lane(id: u64, workflow: &str, rank: usize, event: &str) -> PickRun {
        PickRun {
            path: workflow.into(),
            rank,
            event: event.into(),
            started: 1000 + id as i64,
            ..pick(id)
        }
    }

    /// A project with two declared lanes, the second with a nightly behind two newer runs.
    fn two_lanes() -> Vec<PickRun> {
        vec![
            in_lane(9, "unit.yml", 0, "pull_request"),
            in_lane(8, "unit.yml", 0, "schedule"),
            in_lane(7, "play.yml", 1, "pull_request"),
            in_lane(6, "play.yml", 1, "pull_request"),
            in_lane(5, "play.yml", 1, "schedule"),
        ]
    }

    fn ran(id: u64) -> Loaded {
        Loaded {
            suites: vec![suite(
                "unit",
                &format!("run{id}.bats"),
                &["passed", "failed"],
            )],
            ..Default::default()
        }
    }

    #[test]
    fn a_project_with_two_lanes_draws_two_lanes_each_on_its_latest_nightly() {
        let b = Builds::default();
        let v = page(
            &b,
            &two_lanes(),
            ("", ""),
            &["unit.yml", "play.yml"],
            |r| Some(ran(r.id)),
            &Query::default(),
        );
        let lanes = v["lanes"].as_array().unwrap();
        assert_eq!(lanes.len(), 2);
        assert_eq!(lanes[0]["workflow"], "unit.yml");
        assert_eq!(
            lanes[0]["run"]["id"], 8,
            "the nightly, not the newest pull request run"
        );
        assert_eq!(lanes[1]["workflow"], "play.yml");
        assert_eq!(lanes[1]["run"]["id"], 5);
        assert_eq!(
            lanes[1]["runs"].as_array().unwrap().len(),
            3,
            "each lane lists its own runs"
        );
        assert_eq!(lanes[1]["rows"][0]["suite"], "run5.bats");
        assert_eq!(v["totals"]["suites"], 2, "the totals add the lanes up");
        assert_eq!(v["totals"]["failed"], 2);
        assert_eq!(v["table"]["total"], 2, "the bar counts every lane's suites");
    }

    #[test]
    fn a_run_asked_for_moves_only_its_own_lane() {
        let b = Builds::default();
        let v = page(
            &b,
            &two_lanes(),
            ("", "6"),
            &["unit.yml", "play.yml"],
            |r| Some(ran(r.id)),
            &Query::default(),
        );
        assert_eq!(v["lanes"][0]["run"]["id"], 8);
        assert_eq!(v["lanes"][1]["run"]["id"], 6);
        assert_eq!(
            (
                v["lanes"][0]["pinned"].as_bool(),
                v["lanes"][1]["pinned"].as_bool()
            ),
            (Some(false), Some(true)),
            "only the lane the human picked in is pinned"
        );
        let v = page(
            &b,
            &two_lanes(),
            ("", "9,6"),
            &["unit.yml", "play.yml"],
            |r| Some(ran(r.id)),
            &Query::default(),
        );
        assert_eq!(
            (
                v["lanes"][0]["run"]["id"].as_u64(),
                v["lanes"][1]["run"]["id"].as_u64()
            ),
            (Some(9), Some(6)),
            "one id a lane"
        );
        // a run that aged out falls back to every default, with a word
        let v = page(
            &b,
            &two_lanes(),
            ("", "99"),
            &["unit.yml", "play.yml"],
            |r| Some(ran(r.id)),
            &Query::default(),
        );
        assert_eq!(v["lanes"][1]["run"]["id"], 5);
        assert!(v["errors"][0].as_str().unwrap().contains("run 99"));
    }

    #[test]
    fn a_declared_lane_with_no_finished_run_keeps_its_name_and_a_note_not_an_error() {
        let b = Builds::default();
        let runs = vec![in_lane(9, "unit.yml", 0, "schedule")];
        let v = page(
            &b,
            &runs,
            ("", ""),
            &["unit.yml", "play.yml"],
            |r| Some(ran(r.id)),
            &Query::default(),
        );
        let lanes = v["lanes"].as_array().unwrap();
        assert_eq!(lanes.len(), 2);
        assert_eq!(lanes[1]["workflow"], "play.yml");
        assert_eq!(lanes[1]["run"], serde_json::Value::Null);
        assert!(lanes[1]["note"]
            .as_str()
            .unwrap()
            .contains("play.yml: no finished run"));
        assert!(lanes[1]["errors"].as_array().unwrap().is_empty());
        assert!(v["errors"].as_array().unwrap().is_empty());
        assert_eq!(
            lanes[0]["note"],
            serde_json::Value::Null,
            "the lane with a run has no note"
        );
    }

    #[test]
    fn the_repo_asked_for_scopes_the_lanes_else_the_newest_runs_repo() {
        let mut quiet = pick(3);
        quiet.repo = "Org/quiet".into();
        let runs = [pick(7), pick(6), quiet];
        assert_eq!(choose_repo(&runs, "org/QUIET", &[]).0, Some("Org/quiet"));
        assert_eq!(
            choose_repo(&runs, "", &[3]).0,
            Some("Org/quiet"),
            "a run names its repo"
        );
        assert_eq!(
            choose_repo(&runs, "Org/app", &[3]).0,
            Some("Org/app"),
            "the repo asked for wins"
        );
        let (r, why) = choose_repo(&runs, "Org/gone", &[]);
        assert_eq!(r, Some("Org/app"));
        assert!(why.unwrap().contains("Org/gone has no finished test runs"));
        assert!(choose_repo(&[], "Org/gone", &[5]).0.is_none());
        // the body offers every repo and only the chosen repo's lanes
        let b = Builds::default();
        let v = page(
            &b,
            &runs,
            ("Org/quiet", ""),
            &[],
            |_| None,
            &Query::default(),
        );
        assert_eq!(v["repos"], serde_json::json!(["Org/app", "Org/quiet"]));
        assert_eq!(v["repo"], "Org/quiet");
        assert_eq!(v["lanes"][0]["runs"].as_array().unwrap().len(), 1);
    }

    fn quarantined_builds() -> Builds {
        use hub_core::quarantine::{Held, Nightly, OwnerRow, Report};
        let held = |test: &str, row: &str, days_left: i64| Held {
            test: test.into(),
            ends: "2026-11-20".into(),
            row: row.into(),
            owner: format!("{row} fix: it"),
            days_left,
        };
        Builds {
            at: 300,
            quarantine: vec![Lane {
                repo: "org/APP".into(),
                report: Some(Report {
                    entries: 3,
                    rows: vec![OwnerRow {
                        row: "ucp-2".into(),
                        entries: 1,
                        ends: "2026-11-11".into(),
                        days_left: -1,
                    }],
                    tests: vec![
                        held("A.t1", "ucp-1", 8),
                        held("A.gone", "ucp-2", -1),
                        held("B.t0", "", 2),
                    ],
                }),
                nightly: Some(Nightly {
                    url: Some("https://github.com/org/APP/actions/runs/9".into()),
                    known: 2,
                    now_passing: Some(1),
                    now_passing_tests: vec!["B.t0".into()],
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn held_body(l: &Loaded, q: Query) -> serde_json::Value {
        let b = quarantined_builds();
        page(&b, &[pick(7)], ("", ""), &[], |_| Some(l.clone()), &q)
    }

    #[test]
    fn a_failure_the_runs_repo_holds_in_quarantine_is_amber_not_red() {
        let mut a = suite("playmode", "A", &["passed", "failed"]);
        a.cases[1].fullname = "A.t1".into();
        let mut gone = suite("playmode", "G", &["failed"]);
        gone.cases[0].fullname = "A.gone".into();
        let l = Loaded {
            suites: vec![
                Suite::new("playmode", "A", a.cases),
                Suite::new("playmode", "G", gone.cases),
            ],
            ..Default::default()
        };
        let v = held_body(&l, Query::default());
        let row = |name: &str| {
            lane(&v)["rows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["suite"] == name)
                .cloned()
                .unwrap()
        };
        assert_eq!(row("A")["state"], "quarantined");
        assert_eq!(row("A")["level"], "warn");
        assert_eq!(row("A")["quarantined"], 1);
        assert_eq!(
            row("G")["state"],
            "failed",
            "a test past its end is red again"
        );
        assert_eq!(v["totals"]["failed"], 1);
        assert_eq!(v["totals"]["quarantined"], 1);
        assert_eq!(v["totals"]["failed_suites"], 1);
        let chip = v["table"]["states"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == "quarantined")
            .cloned()
            .unwrap();
        assert_eq!(chip["n"], 1);
        // negative control: the same results with no quarantine are both red
        let v = body(Some(&l), Query::default());
        assert_eq!(v["totals"]["failed"], 2);
        assert_eq!(v["totals"]["quarantined"], 0);
    }

    #[test]
    fn the_quarantine_table_lists_each_held_test_with_its_lane_line() {
        let v = held_body(&Loaded::default(), Query::default());
        let q = &v["quarantine"];
        assert_eq!(
            q["lanes"][0]["url"],
            "https://github.com/org/APP/actions/runs/9"
        );
        assert_eq!(q["lanes"][0]["level"], "bad");
        assert!(q["lanes"][0]["says"]
            .as_str()
            .unwrap()
            .contains("2 known red"));
        let tests: Vec<&str> = q["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["test"].as_str().unwrap())
            .collect();
        assert_eq!(tests, ["A.gone", "B.t0", "A.t1"], "the soonest end first");
        assert_eq!(q["rows"][1]["nightly"], "now passing");
        assert_eq!(q["rows"][0]["left"], "ended");
        assert_eq!(q["table"]["total"], 3);
        assert_eq!(q["table"]["links"][0]["row"], "#projects/all?q=id:=ucp-2");
        let v = held_body(
            &Loaded::default(),
            Query {
                qs: "ended".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 1);
        let v = held_body(
            &Loaded::default(),
            Query {
                qq: "nightly:failing".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 2);
        // the suites' view keys leave the Quarantine table alone
        let v = held_body(
            &Loaded::default(),
            Query {
                ts: "failed".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 3);
        // no file: no lanes, no rows, no error
        let v = body(None, Query::default());
        assert!(v["quarantine"]["lanes"].as_array().unwrap().is_empty());
        assert_eq!(v["quarantine"]["error"], serde_json::Value::Null);
    }
}
