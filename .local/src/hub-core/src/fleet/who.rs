//! The Fleet tab's one table: who is working, on what, and can I afford it. Tier 1 is the
//! supervisors (a runner whose conf says `TIER=1`), tier 2 every other agentctl runner, tier 3
//! every live session from fleet-sessions' `state.json`. It is a [`Row`], so both surfaces get
//! the shared table's search, chips and sort, and a row opens its own record: a runner's page
//! or the Sessions record. A tier 1 row can fold the rows under it (`OVERSEES=` in its conf).

use std::collections::HashSet;

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

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Who {
    pub tier: u8,
    pub who: String,
    pub opens: Opens,
    /// What the row opens: the runner's name or the session's tmux target.
    pub key: String,
    /// failed, stalled, needs you, working, idle, off, chat, landed, parked ...
    pub state: String,
    /// When it started its present state, unix seconds.
    pub since: Option<i64>,
    pub doing: String,
    pub under: String,
    pub cost: Option<f64>,
    /// A runner's lane, a session's project.
    pub project: String,
    /// The tier 1 row that folds this one.
    pub parent: Option<String>,
    /// How many rows a tier 1 row folds.
    pub kids: usize,
}

impl Row for Who {
    const COLUMNS: &'static [&'static str] = &[
        "tier", "who", "state", "since", "doing", "under", "cost", "project",
    ];
    const STATES: &'static [&'static str] = &["all", "failed", "working", "needs you", "stalled"];
    const FACETS: &'static [&'static str] = &["tier", "state", "project"];

    fn val(&self, col: &str) -> Val {
        let text = |t: &str| {
            if t.is_empty() {
                Val::None
            } else {
                Val::Text(t.into())
            }
        };
        match col {
            "tier" => Val::Num(f64::from(self.tier)),
            "who" => Val::Text(self.who.clone()),
            "state" => Val::Text(self.state.clone()),
            "since" => self.since.map_or(Val::None, |t| Val::Num(t as f64)),
            "doing" => text(&self.doing),
            "under" => text(&self.under),
            "cost" => self.cost.map_or(Val::None, Val::Num),
            "project" => text(&self.project),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        self.state == state
    }
}

/// How urgent a state is: the table's own order puts these first within a tier.
fn rank(state: &str) -> u8 {
    match state {
        "failed" => 0,
        "needs you" => 1,
        "stalled" => 2,
        _ => 3,
    }
}

fn runner(w: &Worker, at: i64) -> Who {
    let state = if w.failed_24h > 0 {
        "failed"
    } else if w.overdue {
        "stalled"
    } else {
        &w.state
    };
    let doing = match (&w.why, w.running_since, w.next) {
        (_, Some(_), _) if w.why.is_none() => "running".to_string(),
        (Some(o), ..) => format!("{} {}", o.word, o.text).trim().to_string(),
        (None, None, Some(n)) if n > at => format!("next {}", clock(n)),
        _ => String::new(),
    };
    Who {
        tier: if w.tier == 0 { 2 } else { w.tier },
        who: w.name.clone(),
        opens: Opens::Runner,
        key: w.name.clone(),
        state: state.into(),
        since: w.running_since.or(w.last.as_ref().and_then(|o| o.at)),
        doing,
        under: w
            .called_by
            .as_ref()
            .map_or(String::new(), |c| format!("called by {c}")),
        cost: w.cost_24h,
        project: w.lane.clone(),
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
fn name_of(target: &str) -> String {
    match target.split_once('/') {
        Some(("lab", rest)) => rest.strip_suffix(":1").unwrap_or(rest).to_string(),
        Some((_, rest)) => rest.to_string(),
        None => target.to_string(),
    }
}

/// The project a session works in: the dispatcher's `project: item` when it has one, else
/// the repo its tmux session is named for (`dotfiles-agent-3` -> `dotfiles`).
fn project_of(sess: &Value, name: &str) -> String {
    if let Some((p, _)) = s(sess, "dispatch").split_once(": ") {
        return p.to_string();
    }
    let base = name.split(':').next().unwrap_or(name);
    match base.rsplit_once("-agent-") {
        Some((p, n)) if n.chars().all(|c| c.is_ascii_digit()) => p.to_string(),
        _ => base.to_string(),
    }
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
    let doing = [s(sess, "doing"), s(sess, "topic")]
        .into_iter()
        .find(|d| !d.is_empty())
        .unwrap_or_default();
    Some(Who {
        tier: 3,
        project: project_of(sess, &name),
        who: name,
        opens: Opens::Session,
        key: target.to_string(),
        state,
        since: sess["age_min"].as_i64().map(|m| at - m * 60),
        doing: doing.to_string(),
        under,
        cost: None,
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
             "doing": "Bash: tests", "topic": "moonlit P3",
             "dispatch": "agent-runtime: moonlit-p3", "item": {"slug": "moonlit-p3", "origin": "run"}},
            {"target": "hub/dotfiles:2", "bucket": "CHAT", "age_min": 4, "doing": "", "topic": "fleet tab plan",
             "item": null},
            {"target": "lab/ucp-agent-9:1", "bucket": "NEEDS", "age_min": 90, "doing": "asks",
             "item": {"slug": "x", "origin": "hand"}},
        ]})
    }

    fn rows() -> Vec<Who> {
        let mut failed = worker("ask-judge", 0, "");
        failed.failed_24h = 2;
        failed.last = Some(Outcome {
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

    #[test]
    fn a_runner_with_a_failure_reads_failed_and_a_session_reads_its_bucket() {
        let r = rows();
        let st = |n: &str| r.iter().find(|x| x.who == n).unwrap().state.clone();
        assert_eq!(st("ask-judge"), "failed");
        assert_eq!(st("ucp-agent-9"), "needs you");
        assert_eq!(st("dotfiles:2"), "chat");
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
        assert_eq!((h.under.as_str(), h.project.as_str()), ("by hand x", "ucp"));
        assert_eq!(s.since, Some(1000 - 21 * 60));
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
        let v = View::new::<Who>("tier:3 state:\"needs you\"", "", "", "");
        let got = v.apply(&r);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].who, "ucp-agent-9");
    }
}
