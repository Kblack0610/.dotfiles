//! The Fleet tab's one table: who is working, on what, and why each one is deployed (what
//! each runner spent is `crate::costs`). Each row has a KIND: `lead` for the supervisors (a
//! runner whose conf says `TIER=1`, tier 1), the conf's `LANE` for every other agentctl runner
//! (tier 2), `session` for every live session from fleet-sessions' `state.json` (tier 3). FOR is
//! why it is there: a runner's conf `DESCRIPTION`, what a session is on. The legend above the
//! table is agentctl's `lanes.tsv` (`legend`), so no meaning is written here. It is a [`Row`], so
//! both surfaces get the shared table's search, chips and sort, and a row opens its own record:
//! a runner's page or the Sessions record. A tier 1 row can fold the rows under it (`OVERSEES=`
//! in its conf).

use std::collections::HashSet;
use std::path::Path;

use chrono::{Local, TimeZone};
use serde::Serialize;
use serde_json::Value;

use super::Worker;
use crate::table::{Row, Val, View};

/// What a row opens: a runner's page or a session's record.
#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Opens {
    Runner,
    Session,
}

/// `OVERSEES=` values: every live session, or only the ones the dispatcher started.
const ALL_SESSIONS: &str = "sessions";
const DISPATCHED: &str = "dispatched";
/// A queue item whose origin is one of these was started by fleet-dispatch.
const DISPATCH_ORIGINS: [&str; 2] = ["run", "redispatch"];
/// The KIND of a tier 1 runner and of a live session; any other runner's is its conf `LANE`.
pub const LEAD: &str = "lead";
pub const SESSION: &str = "session";

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Who {
    /// 1 a lead, 2 another runner, 3 a session: the table's own order and what folds.
    pub tier: u8,
    /// `lead`, the runner's lane, or `session`.
    pub kind: String,
    pub who: String,
    pub opens: Opens,
    /// What the row opens: the runner's name or the session's tmux target.
    pub key: String,
    /// failed, stalled, needs you, working, idle, off, chat, landed, parked ...
    pub state: String,
    /// When it started its present state, unix seconds.
    pub since: Option<i64>,
    /// A runner's Claude Code cost over the last 24h (`Worker::cost_24h`); None for a session.
    pub cost_24h: Option<f64>,
    /// What a session is doing now, fleet-sessions' `activity_line` (testing, editing, waiting on
    /// <workflow> Nm, red on <workflow>, gating, its status); blank for a runner.
    pub activity: String,
    /// Why it is deployed: a runner's conf `DESCRIPTION`, what a session is on.
    #[serde(rename = "for")]
    pub purpose: String,
    /// What it is doing, or its last run; `(N failed 24h)` when any run failed in the day.
    pub doing: String,
    pub under: String,
    /// A session's project; blank for a runner, whose lane is its kind.
    pub project: String,
    /// The tier 1 row that folds this one.
    pub parent: Option<String>,
    /// How many rows a tier 1 row folds.
    pub kids: usize,
}

impl Row for Who {
    const COLUMNS: &'static [&'static str] = &[
        "kind", "who", "state", "cost", "activity", "since", "for", "doing", "under", "project",
    ];
    /// The kind chips, then the state chips.
    const STATES: &'static [&'static str] = &[
        "all",
        LEAD,
        "deliver",
        "observe",
        "learn",
        "maintain",
        SESSION,
        "held",
        "failed",
        "working",
        "needs you",
        "stalled",
    ];
    const FACETS: &'static [&'static str] = &["kind", "state", "project"];
    const LEAD: &'static str = "doing";
    const GLANCE: &'static [&'static str] = &["who", "state", "for"];

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
            "activity" => text(&self.activity),
            "since" => self.since.map_or(Val::None, |t| Val::Num(t as f64)),
            "cost" => self.cost_24h.map_or(Val::None, Val::Num),
            "for" => text(&self.purpose),
            "doing" => text(&self.doing),
            "under" => text(&self.under),
            "project" => text(&self.project),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        self.state == state || self.kind == state
    }
}

/// How urgent a state is: the table's own order puts these first within a tier.
fn rank(state: &str) -> u8 {
    match state {
        "failed" => 0,
        "held" => 1,
        "needs you" => 2,
        "stalled" => 3,
        _ => 4,
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
        opens: Opens::Runner,
        key: w.name.clone(),
        state: state.into(),
        since: w
            .held_since
            .or(w.running_since)
            .or(call.map(|c| c.at))
            .or(w.last.as_ref().and_then(|o| o.at)),
        cost_24h: w.cost_24h,
        activity: String::new(),
        purpose: w.description.clone(),
        doing,
        under: w
            .called_by
            .as_ref()
            .map_or(String::new(), |c| format!("called by {c}")),
        project: String::new(),
        parent: None,
        kids: 0,
    }
}

/// HH:MM local.
fn clock(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map_or_else(String::new, |d| d.format("%H:%M").to_string())
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or_default()
}

/// A session's tmux target as the table names it: `lab/dotfiles-agent-3:1` is
/// `dotfiles-agent-3`, `hub/dotfiles:2` stays as it is past the world.
pub(crate) fn name_of(target: &str) -> String {
    match target.split_once('/') {
        Some(("lab", rest)) => rest.strip_suffix(":1").unwrap_or(rest).to_string(),
        Some((_, rest)) => rest.to_string(),
        None => target.to_string(),
    }
}

/// The project a session works in: the dispatcher's `project: item` when it has one, else the
/// `project` its row carries, which `fleet-sessions` resolves from the cwd through
/// `project-map.json` (a `freqtrade_trading_attempt-agent-3` worktree is `trader`). Never the tmux
/// session name: that is a worktree, not a project.
fn project_of(sess: &Value) -> String {
    match s(sess, "dispatch").split_once(": ") {
        Some((p, _)) => p,
        None => s(sess, "project"),
    }
    .to_string()
}

fn session(sess: &Value, at: i64) -> Option<Who> {
    let target = s(sess, "target");
    if target.is_empty() {
        return None;
    }
    let name = name_of(target);
    let bucket = s(sess, "bucket");
    let state = match bucket {
        "NEEDS" => "needs you".to_string(),
        b => b.to_lowercase(),
    };
    let item = &sess["item"];
    let by = match s(item, "origin") {
        o if DISPATCH_ORIGINS.contains(&o) => "dispatch",
        "resume" => "resume",
        "hand" => "by hand",
        _ => "",
    };
    let under = [by, s(item, "slug")]
        .iter()
        .filter(|p| !p.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ");
    Some(Who {
        tier: 3,
        kind: SESSION.into(),
        project: project_of(sess),
        who: name,
        opens: Opens::Session,
        key: target.to_string(),
        state,
        since: sess["age_min"].as_i64().map(|m| at - m * 60),
        cost_24h: None,
        activity: s(sess, "activity_line").to_string(),
        // fleet-sessions' topic is what it is on; its queue item's slug is under it.
        purpose: s(sess, "topic").to_string(),
        doing: s(sess, "doing").to_string(),
        under,
        parent: None,
        kids: 0,
    })
}

/// Every runner and live session as one list, in the table's own order: tier, then the
/// states that need a look, then name. `state` is `state.json` (null when unreadable, which
/// leaves tier 3 empty). A tier 1 runner whose conf says `OVERSEES=dispatched` takes the
/// sessions fleet-dispatch started and one with `OVERSEES=sessions` takes the rest.
pub fn build(workers: &[Worker], state: &Value, at: i64) -> Vec<Who> {
    let mut rows: Vec<Who> = workers.iter().map(|w| runner(w, at)).collect();
    let mut kids: Vec<(Who, bool)> = state["sessions"].as_array().map_or(vec![], |a| {
        a.iter()
            .filter_map(|x| {
                session(x, at).map(|w| {
                    let dispatched = DISPATCH_ORIGINS.contains(&s(&x["item"], "origin"));
                    (w, dispatched)
                })
            })
            .collect()
    });
    let boss = |what: &str| {
        workers
            .iter()
            .find(|w| w.tier == 1 && w.oversees == what)
            .map(|w| w.name.clone())
    };
    let (all, dispatched) = (boss(ALL_SESSIONS), boss(DISPATCHED));
    for (w, from_dispatch) in &mut kids {
        w.parent = if *from_dispatch {
            dispatched.clone()
        } else {
            None
        }
        .or_else(|| all.clone());
    }
    rows.extend(kids.into_iter().map(|(w, _)| w));
    for r in &mut rows {
        r.kids = 0;
    }
    let counts: Vec<(String, usize)> = rows.iter().filter_map(|r| r.parent.clone()).fold(
        vec![],
        |mut acc: Vec<(String, usize)>, p| {
            match acc.iter_mut().find(|(n, _)| *n == p) {
                Some((_, n)) => *n += 1,
                None => acc.push((p, 1)),
            }
            acc
        },
    );
    for r in rows.iter_mut().filter(|r| r.opens == Opens::Runner) {
        r.kids = counts
            .iter()
            .find(|(n, _)| *n == r.key)
            .map_or(0, |(_, n)| *n);
        if r.kids > 0 {
            r.under = format!("{} sessions", r.kids);
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

/// `rows` without the rows a folded tier 1 row holds. A search or a chip shows every match,
/// folded or not, so a hit is never hidden under a closed row.
pub fn unfolded<'a>(rows: Vec<&'a Who>, folded: &HashSet<String>, view: &View) -> Vec<&'a Who> {
    if folded.is_empty() || !view.q.is_empty() || !view.state.is_empty() {
        return rows;
    }
    rows.into_iter()
        .filter(|r| r.parent.as_ref().is_none_or(|p| !folded.contains(p)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
                (3, "ucp-agent-9"),
                (3, "dotfiles-agent-3"),
                (3, "dotfiles:2"),
            ]
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
    fn kind_is_lead_the_lane_or_session_and_for_says_why_it_is_deployed() {
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
        assert_eq!(kf("dotfiles-agent-3"), ("session", "moonlit P3"));
        // DOING is what it does, FOR keeps the topic; a runner's lane is no longer its project.
        assert_eq!(row("dotfiles-agent-3").doing, "Bash: tests");
        // ACTIVITY is fleet-sessions' activity_line; a runner has none.
        assert_eq!(row("dotfiles-agent-3").activity, "red on CI");
        assert_eq!(row("briefing").activity, "");
        assert_eq!(row("briefing").project, "");
        let chips = View::default().states(&r);
        let n = |s: &str| chips.iter().find(|c| c.name == s).map(|c| c.n);
        assert_eq!(
            (n("lead"), n("observe"), n("session"), n("deliver")),
            (Some(1), Some(1), Some(3), Some(0))
        );
        let picked = View::new::<Who>("", "session", "", "").apply(&r);
        assert!(picked.len() == 3 && picked.iter().all(|w| w.tier == 3));
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
    fn a_runner_with_a_failure_reads_failed_and_a_session_reads_its_bucket() {
        let r = rows();
        let st = |n: &str| r.iter().find(|x| x.who == n).unwrap().state.clone();
        assert_eq!(st("ask-judge"), "failed");
        assert_eq!(st("ucp-agent-9"), "needs you");
        assert_eq!(st("dotfiles:2"), "chat");
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
    fn a_dispatched_session_folds_under_fleet_dispatch_and_the_rest_under_shepherd() {
        let r = rows();
        let p = |n: &str| r.iter().find(|x| x.who == n).unwrap().parent.clone();
        assert_eq!(p("dotfiles-agent-3").as_deref(), Some("fleet-dispatch"));
        assert_eq!(p("dotfiles:2").as_deref(), Some("shepherd"));
        assert_eq!(p("ask-judge"), None);
        let k = |n: &str| r.iter().find(|x| x.who == n).unwrap().kids;
        assert_eq!((k("fleet-dispatch"), k("shepherd")), (1, 2));
    }

    #[test]
    fn a_session_row_says_who_started_it_and_names_its_project() {
        let r = rows();
        let s = r.iter().find(|x| x.who == "dotfiles-agent-3").unwrap();
        assert_eq!(s.under, "dispatch moonlit-p3");
        assert_eq!(
            (s.project.as_str(), s.opens),
            ("agent-runtime", Opens::Session)
        );
        assert_eq!(s.key, "lab/dotfiles-agent-3:1");
        let h = r.iter().find(|x| x.who == "ucp-agent-9").unwrap();
        assert_eq!(
            (h.under.as_str(), h.project.as_str()),
            ("by hand x", "unity-core-playground")
        );
        assert_eq!(s.since, Some(1000 - 21 * 60));
        // A row with no project and no dispatch says nothing, never a guess from its name.
        let chat = r.iter().find(|x| x.who == "dotfiles:2").unwrap();
        assert_eq!(chat.project, "");
    }

    #[test]
    fn folding_hides_only_the_closed_rows_kids_and_never_a_search_hit() {
        let r = rows();
        let all: Vec<&Who> = r.iter().collect();
        let folded: HashSet<String> = ["shepherd".to_string()].into();
        let v = View::default();
        let names = |rows: Vec<&Who>| rows.iter().map(|r| r.who.clone()).collect::<Vec<_>>();
        let got = names(unfolded(all.clone(), &folded, &v));
        assert!(!got.contains(&"dotfiles:2".to_string()));
        assert!(got.contains(&"dotfiles-agent-3".to_string()));
        let searching = View::new::<Who>("dotfiles", "", "", "");
        assert_eq!(
            names(unfolded(all.clone(), &folded, &searching)).len(),
            all.len()
        );
    }

    #[test]
    fn an_unreadable_state_leaves_the_runners() {
        let r = build(&[worker("a", 0, "")], &Value::Null, 0);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].tier, 2);
    }

    #[test]
    fn the_columns_are_searchable_by_key() {
        let r = rows();
        let v = View::new::<Who>("kind:session state:\"needs you\"", "", "", "");
        let got = v.apply(&r);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].who, "ucp-agent-9");
    }
}
