//! Sessions' Runners inner tab: hub-core's `fleet`, shared with the TUI. The files are read on
//! every request, so a file event shows at once; judge-eval's answer, the one slow part (seconds),
//! is kept (`Cache`) and handed in. A runner's page (`/api/fleet/runner?name=`) is read only when
//! it is opened, from the same kept judge-eval. The accounts, tokens and Langfuse are the Costs tab's (costs.rs).
//! The answer judge's verdicts are a table of their own under the `v` key prefix (`vq`, `vs`,
//! `vsort`, `vdir`), on Log's Judges section and on the ask-judge runner page alike.

use hub_core::fleet::{self, who::Who, AskVerdict, Fleet, Paths};
use hub_core::table::{self, View};
use serde::Deserialize;

use tokio::sync::broadcast;

use crate::cache::{off, EventCache};
use crate::Shared;

/// The files that reach the page as a `fleet` event (main.rs `classify`): the run ledger and
/// dispatch's verdicts and log.
const KINDS: [&str; 1] = ["fleet"];
/// Not every ledger judge-eval scores pushes an event, and a verdict a minute late changes no
/// decision, so its answer is not kept past this.
const READ_FOR_SECS: u64 = 60;

/// The one kept `judge-eval --all --json`, which Runners, Log's Judges and a judge's runner page
/// read. A failed run is not kept, so the next request runs it again.
pub struct Cache(EventCache<Result<String, String>, READ_FOR_SECS>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS, "judge-eval"))
    }

    pub async fn judge_eval(&self) -> Result<String, String> {
        self.0
            .get_if((), || fleet::judge_eval(&Paths::from_env()), Result::is_ok)
            .await
            .and_then(|r| r.as_ref().clone())
    }
}

/// The table view the page keeps in its URL. Runners shares `#sessions?...` with the Sessions
/// table, so its keys carry the `r` prefix (`rq`, `rs`, `rsort`, `rdir`; table.js `pre`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct FleetQuery {
    pub rq: String,
    pub rs: String,
    pub rsort: String,
    pub rdir: String,
    /// The page Log's dispatch judge list is on, under the `d` prefix (it has no other view key).
    pub dpg: String,
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
}

/// The answer judge's verdicts' view, under the `v` prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct VerdictQuery {
    pub vq: String,
    pub vs: String,
    pub vsort: String,
    pub vdir: String,
    /// The page Log's list is on; a runner page lists the first.
    pub vpg: String,
}

impl VerdictQuery {
    fn view(&self) -> View {
        View::new::<AskVerdict>(&self.vq, &self.vs, &self.vsort, &self.vdir)
    }
}

/// A runner's page: its name, required (a request without one is a 400), and the verdicts' view
/// when it is the answer judge's.
#[derive(Deserialize)]
pub struct RunnerQuery {
    pub name: String,
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
}

/// A runners read: the files afresh, judge-eval's answer from the kept one.
pub async fn get(c: &Cache, q: FleetQuery) -> String {
    let judge_eval = c.judge_eval().await;
    let f = off(move || fleet::files_with(&Paths::from_env(), judge_eval))
        .await
        .unwrap_or_else(|e| Fleet {
            errors: vec![e],
            ..Default::default()
        });
    render(f, &q)
}

/// The Fleet with its `who` rows cut to the view, the controls that drew them (`table`), and the
/// page of each verdict list Log lists, Judges' `layout::page_rows` a page. The dispatch list is
/// no shared table, so its pager rides beside it (`dispatch_table`: `shown` and `pager`).
fn render(mut f: Fleet, q: &FleetQuery) -> String {
    let per = hub_core::layout::page_rows("verdicts");
    f.judge
        .view(&q.verdicts.view(), q.verdicts.vpg.parse().unwrap_or(1), per);
    let dispatch_table = table::paged(&mut f.dispatch.recent, q.dpg.parse().unwrap_or(1), per);
    let view = View::new::<Who>(&q.rq, &q.rs, &q.rsort, &q.rdir);
    let all = std::mem::take(&mut f.who);
    let (rows, table) = view.summary(&all);
    let out = serde_json::to_value(&f).map(|mut v| {
        v["who"] = serde_json::json!(rows);
        v["table"] = serde_json::json!(table);
        v["dispatch_table"] = serde_json::json!(dispatch_table);
        v
    });
    out.and_then(|v| serde_json::to_string(&v))
        .unwrap_or_else(|e| {
            serde_json::json!({"errors": [e.to_string()], "workers": [], "who": []}).to_string()
        })
}

/// How many rows each list on a runner's page draws: a glance at the runner's record, not a long
/// list. The runs, the activity, the calls, the per-rule eval, the answer judge's cells and the
/// conf list nowhere else and the reader bounds them (hub-core `fleet::runner`: 20 runs, activity
/// lines and calls), so their "+N more" draws the rest in place with no read. The judges'
/// verdicts and the intake steps list in Log, so those glances end in a link there instead; the
/// answer judge's verdicts are its first page, cut here. Holds a runner page under three screens at 1400x900
/// (tests/agent-web/phone/fixtures.mjs reads this line). Live data, 2026-11-15, every list drawn:
/// inbox-triage 4,955 px, shepherd 3,310; at 3 the fixtures read ask-judge 2,380 (the tallest),
/// at 4 it was 2,606, too close to 2,700. Revisit when a list's row height or the page's sections
/// change. Web only: the hub TUI scrolls the whole page.
pub const RUNNER_ROWS: usize = 3;

/// One runner's page, read only when `#sessions/runners/<name>` opens, with `shown`, its lists'
/// cap. An unknown name is the caller's 404. A judge's page takes judge-eval from the kept one,
/// asked from the blocking read only when the page is a judge's.
pub async fn runner(s: Shared, q: RunnerQuery) -> Result<String, String> {
    let name = q.name.clone();
    let rt = tokio::runtime::Handle::current();
    let judge_eval = move || rt.block_on(s.fleet.judge_eval());
    let mut r =
        off(move || fleet::runner::read_with(&Paths::from_env(), &name, &judge_eval)).await??;
    if let fleet::runner::Extras::AskJudge { judge } = &mut r.extras {
        judge.view(&q.verdicts.view(), 1, RUNNER_ROWS);
    }
    page(&r)
}

/// The runner page's JSON: the reader's fields and `shown` (`RUNNER_ROWS`), so the page holds no
/// copy of the cap.
#[derive(serde::Serialize)]
struct Page<'a> {
    #[serde(flatten)]
    runner: &'a fleet::runner::Runner,
    shown: usize,
}

fn page(r: &fleet::runner::Runner) -> Result<String, String> {
    serde_json::to_string(&Page {
        runner: r,
        shown: RUNNER_ROWS,
    })
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(tier: u8, who: &str, state: &str) -> Who {
        Who {
            tier,
            kind: if tier == 1 { "lead" } else { "observe" }.into(),
            who: who.into(),
            state: state.into(),
            since: None,
            cost_24h: None,
            cost_estimated: false,
            purpose: String::new(),
            doing: String::new(),
            under: String::new(),
        }
    }

    fn fleet() -> Fleet {
        Fleet {
            who: vec![row(1, "shepherd", "working"), row(2, "briefing", "failed")],
            ..Fleet::default()
        }
    }

    fn who_of(s: &str) -> serde_json::Value {
        serde_json::from_str(s).unwrap()
    }

    fn read(q: &FleetQuery) -> serde_json::Value {
        who_of(&render(fleet(), q))
    }

    #[test]
    fn each_row_links_its_runner_page_on_sessions_runners() {
        let v = read(&FleetQuery::default());
        assert_eq!(v["who"].as_array().unwrap().len(), 2);
        assert_eq!(v["table"]["shown"], 2);
        assert_eq!(v["dispatch_table"], serde_json::json!({"shown": 0}));
        assert_eq!(
            v["table"]["links"],
            serde_json::json!([{"who": "#sessions/runners/shepherd"}, {"who": "#sessions/runners/briefing"}])
        );
    }

    #[test]
    fn the_verdicts_view_rides_the_fleet_read_and_counts_every_verdict() {
        let uri = "/api/fleet?rq=lab&vs=wrong&vq=ship".parse().unwrap();
        let axum::extract::Query(q) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        assert_eq!((q.rq.as_str(), q.verdicts.vs.as_str()), ("lab", "wrong"));
        let wrong = |question: &str| AskVerdict {
            question: question.into(),
            score: "wrong".into(),
            ..Default::default()
        };
        let per = hub_core::layout::page_rows("verdicts");
        let mut f = fleet();
        f.judge.verdicts = (0..per + 5).map(|_| wrong("ship it?")).collect();
        f.judge.verdicts.push(wrong("which login?"));
        let v = who_of(&render(f.clone(), &q));
        assert_eq!(
            v["judge"]["verdicts"].as_array().unwrap().len(),
            per,
            "Log's first page"
        );
        assert_eq!(v["judge"]["table"]["shown"], per + 5);
        assert_eq!(v["judge"]["table"]["total"], per + 6);
        assert_eq!(v["judge"]["table"]["pager"]["pages"], 2);
        let uri = "/api/fleet?vs=wrong&vq=ship&vpg=2".parse().unwrap();
        let axum::extract::Query(two) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        let v = who_of(&render(f, &two));
        assert_eq!(
            v["judge"]["verdicts"].as_array().unwrap().len(),
            5,
            "vpg=2 answers page 2"
        );
        assert_eq!(v["judge"]["table"]["pager"]["page"], 2);
        let mut f = fleet();
        f.dispatch.recent = (0..per + 3)
            .map(|i| fleet::Verdict {
                key: format!("row {i}"),
                ..Default::default()
            })
            .collect();
        let v = who_of(&render(f.clone(), &FleetQuery::default()));
        assert_eq!(v["dispatch"]["recent"].as_array().unwrap().len(), per);
        assert_eq!(v["dispatch_table"]["shown"], per + 3);
        assert_eq!(v["dispatch_table"]["pager"]["pages"], 2);
        let uri = "/api/fleet?dpg=2".parse().unwrap();
        let axum::extract::Query(two) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        let v = who_of(&render(f, &two));
        assert_eq!(v["dispatch"]["recent"][0]["key"], format!("row {per}"));
        let uri = "/api/fleet/runner?name=ask-judge&vs=passed"
            .parse()
            .unwrap();
        let axum::extract::Query(r) =
            axum::extract::Query::<RunnerQuery>::try_from_uri(&uri).unwrap();
        assert_eq!(
            (r.name.as_str(), r.verdicts.vs.as_str()),
            ("ask-judge", "passed")
        );
        let bare = "/api/fleet/runner?vs=passed"
            .parse::<axum::http::Uri>()
            .unwrap();
        assert!(
            axum::extract::Query::<RunnerQuery>::try_from_uri(&bare).is_err(),
            "no name is a bad request, not a lookup of the empty name"
        );
    }

    #[test]
    fn the_view_is_read_from_the_r_prefixed_keys() {
        let v = read(&FleetQuery {
            rs: "failed".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["who"][0]["who"], "briefing");
        assert_eq!(v["table"]["links"][0]["who"], "#sessions/runners/briefing");
        let v = read(&FleetQuery {
            rq: "shep".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"][0]["who"], "shepherd");
    }

    #[test]
    fn a_runner_page_sends_its_lists_cap_beside_every_row_the_reader_kept() {
        let r = fleet::runner::Runner {
            name: "inbox-triage".into(),
            activity: vec![Default::default(); 20],
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&page(&r).unwrap()).unwrap();
        assert_eq!(v["shown"], RUNNER_ROWS);
        assert_eq!(
            v["activity"].as_array().unwrap().len(),
            20,
            "the page cuts, not the server"
        );
        assert_eq!(v["name"], "inbox-triage");
    }
}
