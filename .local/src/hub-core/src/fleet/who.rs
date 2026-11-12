//! Sessions' Runners table: every agentctl runner, what it is doing and why it is deployed (what
//! each runner spent is `crate::costs`). Each row has a KIND: `lead` for the supervisors (a
//! runner whose conf says `TIER=1`, tier 1), the conf's `LANE` for every other runner (tier 2).
//! FOR is why it is there, the conf's `DESCRIPTION`. The legend above the table is agentctl's
//! `lanes.tsv` (`legend`), so no meaning is written here. It is a [`Row`], so both surfaces get
//! the shared table's search, chips and sort, and a row opens its runner's page. Live sessions
//! are the Sessions table's rows, not this one's: a lead row's UNDER counts the ones it oversees
//! (`OVERSEES=` in its conf).

use std::path::Path;

use chrono::{Local, TimeZone};
use serde::Serialize;
use serde_json::Value;

use super::Worker;
use crate::links::{Kind, Link};
use crate::session_table::started_by;
use crate::table::{Row, Val};

/// `OVERSEES=` values: every live session, or only the ones the dispatcher started.
const ALL_SESSIONS: &str = "sessions";
const DISPATCHED: &str = "dispatched";
/// The KIND of a tier 1 runner; any other runner's is its conf `LANE`.
pub const LEAD: &str = "lead";

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Who {
    /// 1 a lead, 2 another runner: the table's own order.
    pub tier: u8,
    /// `lead` or the runner's lane.
    pub kind: String,
    /// The runner's name, which its page is keyed by.
    pub who: String,
    /// failed, held, stalled, working, idle, off ...
    pub state: String,
    /// When it started its present state, unix seconds.
    pub since: Option<i64>,
    /// Its cost over the last 24h (`Worker::cost_24h`).
    pub cost_24h: Option<f64>,
    /// Part of `cost_24h` is estimated from tokens: drawn as `~` (`fleet_cost::FLEET_LEGEND`).
    pub cost_estimated: bool,
    /// Why it is deployed: its conf `DESCRIPTION`.
    #[serde(rename = "for")]
    pub purpose: String,
    /// What it is doing, or its last run; `(N failed 24h)` when any run failed in the day.
    pub doing: String,
    /// `called by <caller>`, or for a lead `N sessions`, the live sessions it oversees.
    pub under: String,
}

impl Row for Who {
    const COLUMNS: &'static [&'static str] = &[
        "kind", "who", "state", "cost", "since", "for", "doing", "under",
    ];
    /// The kind chips, then the state chips.
    const STATES: &'static [&'static str] = &[
        "all", LEAD, "deliver", "observe", "learn", "maintain", "held", "failed", "working",
        "stalled",
    ];
    const FACETS: &'static [&'static str] = &["kind", "state"];
    const LEAD: &'static str = "doing";
    const GLANCE: &'static [&'static str] = &["who", "state", "for"];
    /// A held runner is stopped until its budget or hold lifts, so it reads red like its cell.
    const TONES: &'static [(&'static str, crate::vocab::Level)] =
        &[("held", crate::vocab::Level::Bad)];

    fn val(&self, col: &str) -> Val {
        let text = |t: &str| {
            if t.is_empty() {
                Val::None
            } else {
                Val::Text(t.into())
            }
        };
        match col {
            "kind" => text(&self.kind),
            "who" => Val::Text(self.who.clone()),
            "state" => Val::Text(self.state.clone()),
            "since" => self.since.map_or(Val::None, |t| Val::Num(t as f64)),
            "cost" => self.cost_24h.map_or(Val::None, Val::Num),
            "for" => text(&self.purpose),
            "doing" => text(&self.doing),
            "under" => text(&self.under),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        self.state == state || self.kind == state
    }

    /// The name opens the runner's page.
    fn link(&self, col: &str) -> Option<Link> {
        (col == "who").then(|| Link::to(Kind::Runner, &self.who))
    }
}

/// How urgent a state is: the table's own order puts these first within a tier.
fn rank(state: &str) -> u8 {
    match state {
        "failed" => 0,
        "held" => 1,
        "stalled" => 2,
        _ => 3,
    }
}

fn runner(w: &Worker, at: i64) -> Who {
    // Failed is the last run; an older failure in the day is a count on DOING.
    let state = if w.last.as_ref().is_some_and(|o| o.ok == Some(false)) {
        "failed"
    } else if w.held_since.is_some() {
        "held"
    } else if w.overdue {
        "stalled"
    } else if w.state == "running" {
        "working"
    } else {
        &w.state
    };
    // A called runner's outcomes are its calls: its newest, when newer than its last run and its
    // activity line, is its last outcome. A call that succeeds writes no line, so the line would
    // otherwise stand for every call after it.
    let calls = &w.registry.calls;
    let newest = [&w.why, &w.last]
        .into_iter()
        .filter_map(|o| o.as_ref().and_then(|o| o.at))
        .max();
    let call = w
        .called_by
        .as_ref()
        .and(calls.recent.first())
        .filter(|c| newest.is_none_or(|t| c.at > t));
    let doing = match (&w.why, w.running_since, w.next) {
        // The hold's own line says what holds it, and its amount; held_why is its short reason.
        _ if w.held_since.is_some() => match &w.why {
            Some(o) if o.word == "BLOCKED" && !o.text.is_empty() => o.text.clone(),
            _ => w.held_why.clone(),
        },
        // Its dollars are the COST 24H column's.
        _ if call.is_some() => format!(
            "called {}: {} calls 24h",
            call.map_or("", |c| if c.ok { "ok" } else { "error" }),
            calls.n_24h,
        ),
        (_, Some(_), _) if w.why.is_none() => "running".to_string(),
        (Some(o), ..) => format!("{} {}", o.word, o.text).trim().to_string(),
        (None, None, Some(n)) if n > at => format!("next {}", clock(n)),
        _ => String::new(),
    };
    let doing = match w.failed_24h {
        0 => doing,
        n => format!("{doing} ({n} failed 24h)").trim().to_string(),
    };
    let tier = if w.tier == 0 { 2 } else { w.tier };
    Who {
        tier,
        kind: if tier == 1 {
            LEAD.into()
        } else {
            w.lane.clone()
        },
        who: w.name.clone(),
        state: state.into(),
        since: w
            .held_since
            .or(w.running_since)
            .or(call.map(|c| c.at))
            .or(w.last.as_ref().and_then(|o| o.at)),
        cost_24h: w.cost_24h,
        cost_estimated: w.cost_estimated,
        purpose: w.description.clone(),
        doing,
        under: w
            .called_by
            .as_ref()
            .map_or(String::new(), |c| format!("called by {c}")),
    }
}

/// HH:MM local.
fn clock(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map_or_else(String::new, |d| d.format("%H:%M").to_string())
}

/// Every runner as one list, in the table's own order: tier, then the states that need a look,
/// then name. `state` is `state.json` (null when unreadable, which leaves the leads' counts
/// out). A tier 1 runner whose conf says `OVERSEES=dispatched` counts the live sessions
/// fleet-dispatch started and one with `OVERSEES=sessions` counts the rest (all of them when no
/// lead takes the dispatched ones).
pub fn build(workers: &[Worker], state: &Value, at: i64) -> Vec<Who> {
    let mut rows: Vec<Who> = workers.iter().map(|w| runner(w, at)).collect();
    let boss = |what: &str| {
        workers
            .iter()
            .find(|w| w.tier == 1 && w.oversees == what)
            .map(|w| w.name.as_str())
    };
    let (all, dispatched) = (boss(ALL_SESSIONS), boss(DISPATCHED));
    let mut counts: Vec<(&str, usize)> = vec![];
    for x in state["sessions"].as_array().into_iter().flatten() {
        if x["target"].as_str().unwrap_or_default().is_empty() {
            continue;
        }
        let origin = x["item"]["origin"].as_str().unwrap_or_default();
        let lead = if started_by(origin) == "dispatch" {
            dispatched.or(all)
        } else {
            all
        };
        if let Some(lead) = lead {
            match counts.iter_mut().find(|(n, _)| *n == lead) {
                Some((_, n)) => *n += 1,
                None => counts.push((lead, 1)),
            }
        }
    }
    for r in &mut rows {
        if let Some((_, n)) = counts.iter().find(|(n, _)| *n == r.who) {
            r.under = format!("{n} sessions");
        }
    }
    rows.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then(rank(&a.state).cmp(&rank(&b.state)))
            .then_with(|| a.who.cmp(&b.who))
    });
    rows
}

/// The legend above the table: `kind meaning` for each row of agentctl's `lanes.tsv`
/// (`kind<TAB>meaning`, more columns and `#` lines ignored). A file that cannot be read is
/// `-` and why, so the table still shows.
pub fn legend(path: &Path) -> Vec<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let rows: Vec<String> = text
                .lines()
                .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
                .map(|l| {
                    let mut f = l.split('\t').map(str::trim);
                    let kind = f.next().unwrap_or_default();
                    format!("{kind} {}", f.next().unwrap_or_default())
                        .trim()
                        .to_string()
                })
                .collect();
            if rows.is_empty() {
                vec![format!("- ({} lists no kind)", path.display())]
            } else {
                rows
            }
        }
        Err(e) => vec![format!("- ({}: {e})", path.display())],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    use crate::table::View;

    use crate::fleet::Outcome;

    fn worker(name: &str, tier: u8, oversees: &str) -> Worker {
        Worker {
            name: name.into(),
            lane: "ops".into(),
            tier,
            oversees: oversees.into(),
            enabled: true,
            state: "idle".into(),
            ..Default::default()
        }
    }

    fn state() -> Value {
        json!({"sessions": [
            {"target": "lab/dotfiles-agent-3:1", "bucket": "WORKING", "age_min": 21,
             "doing": "Bash: tests", "topic": "moonlit P3", "activity_line": "red on CI",
             "dispatch": "agent-runtime: moonlit-p3", "item": {"slug": "moonlit-p3", "origin": "run"}},
            {"target": "hub/dotfiles:2", "bucket": "CHAT", "age_min": 4, "doing": "", "topic": "fleet tab plan",
             "item": null},
            {"target": "lab/ucp-agent-9:1", "bucket": "NEEDS", "age_min": 90, "doing": "asks",
             "item": {"slug": "x", "origin": "hand"}, "project": "unity-core-playground"},
        ]})
    }

    fn rows() -> Vec<Who> {
        let mut failed = worker("ask-judge", 0, "");
        failed.failed_24h = 2;
        failed.last = Some(Outcome {
            word: "FAILED".into(),
            ok: Some(false),
            at: Some(500),
            ..Default::default()
        });
        build(
            &[
                worker("shepherd", 1, "sessions"),
                worker("fleet-dispatch", 1, "dispatched"),
                worker("zeta", 0, ""),
                failed,
            ],
            &state(),
            1000,
        )
    }

    #[test]
    fn a_runner_links_its_page_on_sessions_runners() {
        let r = rows();
        let (_, t) = View::default().summary(&r);
        let at = |who: &str, c: &str| {
            let i = r.iter().position(|x| x.who == who).unwrap();
            t.links[i].get(c).cloned()
        };
        assert_eq!(
            at("shepherd", "who").as_deref(),
            Some("#sessions/runners/shepherd")
        );
        assert_eq!(at("shepherd", "state"), None);
    }

    #[test]
    fn tiers_come_first_and_the_states_that_need_a_look_lead_each_tier() {
        let r = rows();
        let order: Vec<(u8, &str)> = r.iter().map(|r| (r.tier, r.who.as_str())).collect();
        assert_eq!(
            order,
            [
                (1, "fleet-dispatch"),
                (1, "shepherd"),
                (2, "ask-judge"),
                (2, "zeta"),
            ],
            "no live session is a row here: they are the Sessions table's"
        );
    }

    fn ran(name: &str, word: &str, ok: bool, failed_24h: u32) -> Worker {
        let mut w = worker(name, 2, "");
        w.failed_24h = failed_24h;
        w.last = Some(Outcome {
            word: word.into(),
            ok: Some(ok),
            at: Some(900),
            ..Default::default()
        });
        w.why = Some(Outcome {
            word: word.into(),
            ok: Some(ok),
            at: Some(900),
            text: "6 need you".into(),
        });
        w
    }

    #[test]
    fn failed_is_the_last_run_and_an_older_failure_is_a_count_on_doing() {
        // The negative control: an old failure under a WORKED last run is not failed.
        let r = build(&[ran("briefing", "WORKED", true, 1)], &json!({}), 1000);
        assert_eq!(r[0].state, "idle");
        assert!(!r[0].in_state("failed"));
        assert_eq!(r[0].doing, "WORKED 6 need you (1 failed 24h)");
        let r = build(&[ran("briefing", "FAILED", false, 3)], &json!({}), 1000);
        assert_eq!(r[0].state, "failed");
        assert_eq!(r[0].doing, "FAILED 6 need you (3 failed 24h)");
        // A day with no failure adds nothing.
        let r = build(&[ran("briefing", "WORKED", true, 0)], &json!({}), 1000);
        assert_eq!(r[0].doing, "WORKED 6 need you");
    }

    #[test]
    fn kind_is_lead_or_the_lane_and_for_says_why_it_is_deployed() {
        let mut lead = worker("shepherd", 1, "sessions");
        lead.lane = "deliver".into();
        lead.description = "Moves every session through its plan".into();
        let mut brief = worker("briefing", 2, "");
        brief.lane = "observe".into();
        brief.description = "Morning and evening briefing".into();
        let r = build(&[lead, brief], &state(), 1000);
        let row = |n: &str| r.iter().find(|x| x.who == n).unwrap();
        let kf = |n: &str| (row(n).kind.as_str(), row(n).purpose.as_str());
        assert_eq!(
            kf("shepherd"),
            ("lead", "Moves every session through its plan")
        );
        assert_eq!(kf("briefing"), ("observe", "Morning and evening briefing"));
        let chips = View::default().states(&r);
        let n = |s: &str| chips.iter().find(|c| c.name == s).map(|c| c.n);
        assert_eq!(
            (n("lead"), n("observe"), n("deliver"), n("session")),
            (Some(1), Some(1), Some(0), None)
        );
        let picked = View::new::<Who>("", "lead", "", "").apply(&r);
        assert!(picked.len() == 1 && picked[0].who == "shepherd");
    }

    #[test]
    fn the_legend_is_lanes_tsv_and_a_missing_file_says_so() {
        let dir = std::env::temp_dir().join(format!("who-legend-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("lanes.tsv");
        std::fs::write(
            &p,
            "# kind\tmeaning\twrites\nlead\truns the sessions\t-\n\nobserve\treports\n",
        )
        .unwrap();
        assert_eq!(legend(&p), ["lead runs the sessions", "observe reports"]);
        std::fs::remove_file(&p).unwrap();
        let gone = legend(&p);
        assert!(gone.len() == 1 && gone[0].starts_with("- ("), "{gone:?}");
        std::fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn a_runner_with_a_failure_reads_failed() {
        let r = rows();
        let st = |n: &str| r.iter().find(|x| x.who == n).unwrap().state.clone();
        assert_eq!(st("ask-judge"), "failed");
        assert_eq!(st("zeta"), "idle");
    }

    fn held(name: &str) -> Worker {
        let mut w = worker(name, 2, "");
        w.held_since = Some(400);
        w.held_why = "at its budget cap".into();
        w.why = Some(Outcome {
            word: "BLOCKED".into(),
            at: Some(900),
            text: "budget: over its daily budget: $5.03 of $5 (BUDGET_DAY_USD)".into(),
            ..Default::default()
        });
        w
    }

    #[test]
    fn a_held_runner_reads_held_since_its_first_block_and_leads_its_tier_after_failed() {
        let mut failed = worker("alpha", 2, "");
        failed.failed_24h = 1;
        failed.last = Some(Outcome {
            ok: Some(false),
            ..Default::default()
        });
        let r = build(
            &[worker("aaa", 2, ""), held("ask-judge"), failed],
            &json!({}),
            1000,
        );
        let order: Vec<&str> = r.iter().map(|r| r.who.as_str()).collect();
        assert_eq!(order, ["alpha", "ask-judge", "aaa"]);
        let h = &r[1];
        assert_eq!((h.state.as_str(), h.since), ("held", Some(400)));
        assert_eq!(
            h.doing,
            "budget: over its daily budget: $5.03 of $5 (BUDGET_DAY_USD)"
        );
        assert!(h.in_state("held") && !r[2].in_state("held"));
        let chips = View::default().states(&r);
        let n = |s: &str| chips.iter().find(|c| c.name == s).map(|c| c.n);
        assert_eq!((n("held"), n("failed")), (Some(1), Some(1)));
        let tone = |s: &str| chips.iter().find(|c| c.name == s).map(|c| c.tone);
        // A held runner is stopped, so its tile is red where Queue's held item is amber.
        assert_eq!(tone("held"), Some(Some(crate::vocab::Level::Bad)));
        assert_eq!(
            crate::vocab::tone(&[], "held"),
            Some(crate::vocab::Level::Warn)
        );
    }

    #[test]
    fn a_hold_with_no_blocked_line_says_its_held_why() {
        let mut w = held("ask-judge");
        w.why = None;
        assert_eq!(build(&[w], &json!({}), 1000)[0].doing, "at its budget cap");
    }

    #[test]
    fn a_called_runner_past_its_last_line_reads_its_calls_not_the_old_block() {
        let mut w = worker("ask-judge", 2, "");
        w.called_by = Some("agent-ask".into());
        w.why = held("x").why;
        w.registry.calls.n_24h = 103;
        w.registry.calls.cost_24h = Some(9.85);
        w.registry.calls.recent = vec![crate::fleet::Call {
            at: 950,
            ok: true,
            ..Default::default()
        }];
        w.cost_24h = Some(4.5);
        let r = build(std::slice::from_ref(&w), &json!({}), 1000);
        // Its dollars are the live series' in COST 24H, not the ledger's in the text.
        assert_eq!(r[0].doing, "called ok: 103 calls 24h");
        assert_eq!(r[0].cost_24h, Some(4.5));
        assert_eq!(r[0].since, Some(950));
        // A runner nobody calls keeps its own line.
        let mut own = w.clone();
        own.called_by = None;
        let r = build(&[own], &json!({}), 1000);
        assert!(r[0].doing.starts_with("BLOCKED budget:"), "{}", r[0].doing);
        // The negative control: a call older than the line leaves the line.
        w.registry.calls.recent[0].at = 800;
        let r = build(&[w], &json!({}), 1000);
        assert!(r[0].doing.starts_with("BLOCKED budget:"), "{}", r[0].doing);
    }

    #[test]
    fn a_running_runner_is_working_so_the_working_chip_finds_it() {
        let mut w = worker("dream", 2, "");
        w.state = "running".into();
        w.running_since = Some(100);
        let r = build(&[w], &json!({}), 200);
        assert_eq!(r[0].state, "working");
        assert!(r[0].in_state("working"));
    }

    #[test]
    fn a_lead_counts_the_sessions_it_oversees() {
        let r = rows();
        let under = |n: &str| r.iter().find(|x| x.who == n).unwrap().under.clone();
        // One session the dispatcher started; the hand one and the one with no item are the rest.
        assert_eq!(under("fleet-dispatch"), "1 sessions");
        assert_eq!(under("shepherd"), "2 sessions");
        assert_eq!(
            under("zeta"),
            "",
            "a runner that oversees nothing counts nothing"
        );
        // With no lead for the dispatched ones, the all-sessions lead counts every one.
        let r = build(&[worker("shepherd", 1, "sessions")], &state(), 1000);
        assert_eq!(r[0].under, "3 sessions");
    }

    #[test]
    fn an_unreadable_state_leaves_the_runners() {
        let r = build(
            &[worker("a", 0, ""), worker("s", 1, "sessions")],
            &Value::Null,
            0,
        );
        assert_eq!(r.len(), 2);
        assert_eq!((r[1].tier, r[1].under.as_str()), (2, ""));
    }

    #[test]
    fn the_columns_are_searchable_by_key() {
        let r = rows();
        let v = View::new::<Who>("kind:ops state:failed", "", "", "");
        let got = v.apply(&r);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].who, "ask-judge");
    }
}
