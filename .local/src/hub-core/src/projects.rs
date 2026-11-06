//! The Projects tab for both surfaces: one card per lab project with its open version's
//! progress, pace and finish estimate, and what is in flight on it. Every number is counted,
//! never judged: `notes projects --stats --json` counts the rows, this module does the
//! arithmetic, and a project with no closes in 28 days has no ETA rather than a guess.
//!
//! Queue items name a REPO-side project (`dotfiles`) while cards are LAB projects
//! (`agent-runtime`, `notes-cockpit`). An item joins a card by its `board:<lab>:` origin, by a
//! name both share, or by the one lab project whose registry `repo` is the item's project.
//! Anything else is listed as unlinked, not guessed at.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::home::{self, Running};
use crate::queue::{Item, Queue, State};
use crate::session_actions::Runner;
use crate::tasks::Feed;

/// The open version's rows and closes, as notes-cli counts them (`Progress` there).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Progress {
    pub open: u32,
    pub done: u32,
    pub open_weight: u32,
    pub done_weight: u32,
    pub closed_7d: u32,
    pub closed_28d: u32,
    pub closed_weight_7d: u32,
    pub closed_weight_28d: u32,
}

/// One row of `notes projects --stats --json`: the fields a card shows.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Stats {
    pub profile: String,
    pub name: String,
    pub stage: String,
    /// `focus`, `high`, `low`, empty for normal: the sheet's `#prio/<word>`.
    pub prio: String,
    pub version: Option<String>,
    pub goal: String,
    pub progress: Progress,
    pub status: String,
    pub status_date: String,
}

/// The priority after `cur` in the cycle a key steps through: normal, focus, high, low.
pub fn next_prio(cur: &str) -> &'static str {
    match cur {
        "" => "focus",
        "focus" => "high",
        "high" => "low",
        _ => "normal",
    }
}

/// `notes projects --prio <name> --profile <profile> --set <value>`: the one writer.
pub fn set_prio(
    runner: &dyn Runner,
    profile: &str,
    name: &str,
    value: &str,
) -> Result<String, String> {
    let ok = |s: &str| {
        !s.is_empty()
            && !s.starts_with('-')
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    if !ok(profile) || !ok(name) || !["focus", "high", "low", "normal"].contains(&value) {
        return Err(format!("refusing prio {value} for {profile}/{name}"));
    }
    runner.run(&[
        "notes".into(),
        "projects".into(),
        "--prio".into(),
        name.into(),
        "--profile".into(),
        profile.into(),
        "--set".into(),
        value.into(),
    ])
}

pub fn stats(runner: &dyn Runner) -> Result<Vec<Stats>, String> {
    let out = runner.run(&[
        "notes".into(),
        "projects".into(),
        "--stats".into(),
        "--json".into(),
    ])?;
    serde_json::from_str(&out).map_err(|e| format!("notes projects --stats --json: {e}"))
}

/// project-map.json: `$AGENT_QUEUE_PROJECT_MAP`, else the shared-hooks copy. agent-queue checks
/// `--project` against the same file.
pub fn map_path() -> PathBuf {
    std::env::var("AGENT_QUEUE_PROJECT_MAP").map_or_else(
        |_| agent_panel::session::home().join(".config/shared-hooks/project-map.json"),
        PathBuf::from,
    )
}

/// Each lab project's repo-side name, from project-map.json `trackers.<lab>.repo`.
pub fn repos(map: &str) -> HashMap<String, String> {
    let v: Value = serde_json::from_str(map).unwrap_or_default();
    v["trackers"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(lab, t)| Some((lab.clone(), t["repo"].as_str()?.to_string())))
        .collect()
}

/// One project's card.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Card {
    pub profile: String,
    pub name: String,
    pub stage: String,
    pub prio: String,
    pub version: Option<String>,
    pub goal: String,
    pub progress: Progress,
    /// Closed share of the open version by size weight, 0-100; None when it has no rows.
    pub percent: Option<u32>,
    /// Days to close the open weight at the 28-day close rate; 0 when nothing is open, None
    /// when nothing closed in 28 days.
    pub eta_days: Option<u32>,
    /// Open rows tagged `#requested` (the human's asks of the agents), both lanes.
    pub requested: usize,
    pub inbox: usize,
    pub running: Vec<Running>,
    pub waiting: usize,
    pub queued: usize,
    pub status: String,
    pub status_date: String,
}

impl Card {
    pub fn in_flight(&self) -> bool {
        !self.running.is_empty() || self.waiting > 0
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Projects {
    pub cards: Vec<Card>,
    /// Active queue items no card could claim, as `project: title`.
    pub unlinked: Vec<String>,
    pub errors: Vec<String>,
}

/// `done / (done + open)` by weight, rounded down so 100 means nothing is left.
pub fn percent(p: &Progress) -> Option<u32> {
    let total = p.done_weight + p.open_weight;
    (total > 0).then(|| p.done_weight * 100 / total)
}

/// `open_weight / (closed_weight_28d / 28)`, rounded up.
pub fn eta_days(p: &Progress) -> Option<u32> {
    if p.open_weight == 0 {
        return Some(0);
    }
    (p.closed_weight_28d > 0).then(|| (p.open_weight * 28).div_ceil(p.closed_weight_28d))
}

/// The lab project an item belongs to, by the rules in the module doc.
fn owner(i: &Item, labs: &[&str], repos: &HashMap<String, String>) -> Option<String> {
    let from_board = i
        .from
        .as_deref()
        .and_then(|f| f.strip_prefix("board:"))
        .and_then(|f| f.split(':').next())
        .filter(|p| labs.contains(p));
    if let Some(p) = from_board {
        return Some(p.to_string());
    }
    if labs.contains(&i.project.as_str()) {
        return Some(i.project.clone());
    }
    let mut by_repo = labs
        .iter()
        .filter(|l| repos.get(**l).is_some_and(|r| *r == i.project));
    let one = by_repo.next()?;
    by_repo.next().is_none().then(|| one.to_string())
}

/// The cards, in flight first (running, then waiting), then by closes in 7 days, then name.
pub fn build(
    stats: &[Stats],
    feed: Option<&Feed>,
    state: &Value,
    queue: Option<&Queue>,
    repos: &HashMap<String, String>,
) -> Projects {
    let mut out = Projects::default();
    let labs: Vec<&str> = stats.iter().map(|s| s.name.as_str()).collect();
    let mut cards: Vec<Card> = stats
        .iter()
        .map(|s| Card {
            profile: s.profile.clone(),
            name: s.name.clone(),
            stage: s.stage.clone(),
            prio: s.prio.clone(),
            version: s.version.clone(),
            goal: s.goal.clone(),
            progress: s.progress,
            percent: percent(&s.progress),
            eta_days: eta_days(&s.progress),
            status: s.status.clone(),
            status_date: s.status_date.clone(),
            ..Card::default()
        })
        .collect();
    let at = |cards: &mut Vec<Card>, name: &str| cards.iter().position(|c| c.name == name);
    if let Some(f) = feed {
        for p in &f.projects {
            if let Some(c) = cards
                .iter_mut()
                .find(|c| c.name == p.project && c.profile == p.profile)
            {
                c.inbox = p.inbox;
            }
        }
        for r in f.rows.iter().filter(|r| r.requested) {
            let Some(p) = r.project.as_deref() else {
                continue;
            };
            if let Some(c) = cards
                .iter_mut()
                .find(|c| c.name == p && c.profile == r.profile)
            {
                c.requested += 1;
            }
        }
    }
    if let Some(q) = queue {
        out.errors.extend(q.errors.iter().cloned());
        let by_slug: HashMap<&str, &Item> = q.items.iter().map(|i| (i.slug.as_str(), i)).collect();
        for r in home::running(state, q) {
            let item = by_slug[r.slug.as_str()];
            match owner(item, &labs, repos).and_then(|o| at(&mut cards, &o)) {
                Some(k) => cards[k].running.push(r),
                None => out.unlinked.push(format!("{}: {}", r.project, r.title)),
            }
        }
        for i in q
            .items
            .iter()
            .filter(|i| matches!(i.state, State::Waiting | State::Queued))
        {
            match owner(i, &labs, repos).and_then(|o| at(&mut cards, &o)) {
                Some(k) if i.state == State::Waiting => cards[k].waiting += 1,
                Some(k) => cards[k].queued += 1,
                None => out.unlinked.push(format!("{}: {}", i.project, i.title())),
            }
        }
    }
    cards.sort_by(|a, b| {
        (b.running.len(), b.waiting, b.progress.closed_7d)
            .cmp(&(a.running.len(), a.waiting, a.progress.closed_7d))
            .then_with(|| a.name.cmp(&b.name))
    });
    out.cards = cards;
    out
}

/// A card's one-line progress, the same words on both surfaces:
/// `v0.0.1 53% (314 of 590 by size), 7d 103, 28d 239, ETA 33d`.
pub fn summary(c: &Card) -> String {
    let p = &c.progress;
    let mut s = c.version.clone().unwrap_or_else(|| "no version".into());
    match c.percent {
        Some(pc) => {
            s += &format!(
                " {pc}% ({} of {} by size)",
                p.done_weight,
                p.done_weight + p.open_weight
            )
        }
        None => s += " no rows",
    }
    s += &format!(", 7d {}, 28d {}", p.closed_7d, p.closed_28d);
    s += &match c.eta_days {
        Some(0) => ", nothing open".to_string(),
        Some(d) => format!(", ETA {d}d"),
        None => ", no ETA (no closes in 28d)".to_string(),
    };
    s
}

/// The whole join every surface reads: `notes projects --stats --json`, the inbox feed, fleet
/// state and the queue, built into cards. agent-web's `/api/projects` and `hub projects --json`
/// both call this, so the chip, the phone, the web tab and the TUI agree.
pub fn gather() -> Projects {
    let runner = crate::session_actions::System;
    let repos = std::fs::read_to_string(map_path())
        .map(|t| repos(&t))
        .unwrap_or_default();
    let state = std::fs::read_to_string(crate::boards::fleet_state())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let queue = Queue::read(&runner);
    let feed = crate::tasks::feed(&runner).ok();
    match stats(&runner) {
        Ok(stats) => build(&stats, feed.as_ref(), &state, Some(&queue), &repos),
        Err(e) => Projects {
            errors: vec![e],
            ..Default::default()
        },
    }
}

/// The cards as JSON, each with its `summary` line and `in_flight`, so a reader prints the same
/// words the TUI does and computes nothing.
pub fn to_json(p: &Projects) -> Value {
    let mut v = serde_json::to_value(p).unwrap_or_default();
    if let Some(cards) = v["cards"].as_array_mut() {
        for (j, c) in cards.iter_mut().zip(&p.cards) {
            j["summary"] = summary(c).into();
            j["in_flight"] = c.in_flight().into();
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tasks::{Project, Row};
    use serde_json::json;

    #[test]
    fn each_card_carries_the_summary_the_tui_prints() {
        let c = Card {
            name: "demo".into(),
            version: Some("v0.1.0".into()),
            progress: Progress {
                open: 1,
                done: 1,
                open_weight: 3,
                done_weight: 1,
                ..Default::default()
            },
            percent: Some(25),
            ..Default::default()
        };
        let v = to_json(&Projects {
            cards: vec![c.clone()],
            ..Default::default()
        });
        assert_eq!(v["cards"][0]["summary"], summary(&c));
        assert!(v["cards"][0]["summary"]
            .as_str()
            .unwrap()
            .starts_with("v0.1.0 25% (1 of 4 by size)"));
        assert_eq!(v["cards"][0]["in_flight"], false);
    }

    struct Argv(std::cell::RefCell<Vec<String>>);
    impl Runner for Argv {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            *self.0.borrow_mut() = argv.to_vec();
            Ok(String::new())
        }
    }

    #[test]
    fn the_prio_key_cycles_and_writes_through_the_cli_only() {
        assert_eq!(next_prio(""), "focus");
        assert_eq!(next_prio("focus"), "high");
        assert_eq!(next_prio("high"), "low");
        assert_eq!(next_prio("low"), "normal");
        let r = Argv(Default::default());
        set_prio(&r, "bnb", "shape-city", "focus").unwrap();
        assert_eq!(
            *r.0.borrow(),
            [
                "notes",
                "projects",
                "--prio",
                "shape-city",
                "--profile",
                "bnb",
                "--set",
                "focus"
            ]
        );
        // nothing that could read as a flag, and no value outside the vocabulary, reaches argv
        r.0.borrow_mut().clear();
        assert!(set_prio(&r, "bnb", "--all", "focus").is_err());
        assert!(set_prio(&r, "bnb", "demo", "urgent").is_err());
        assert!(r.0.borrow().is_empty());
    }

    #[test]
    fn a_card_carries_the_sheet_prio() {
        let s: Vec<Stats> =
            serde_json::from_value(json!([{"profile": "bnb", "name": "a", "prio": "focus"}, {"profile": "bnb", "name": "b"}]))
                .unwrap();
        let p = build(&s, None, &json!({}), None, &HashMap::new());
        let prio = |n: &str| p.cards.iter().find(|c| c.name == n).unwrap().prio.clone();
        assert_eq!(prio("a"), "focus");
        assert_eq!(prio("b"), "");
    }

    fn prog(open_w: u32, done_w: u32, closed_28: u32) -> Progress {
        Progress {
            open: open_w,
            done: done_w,
            open_weight: open_w,
            done_weight: done_w,
            closed_28d: closed_28,
            closed_weight_28d: closed_28,
            ..Progress::default()
        }
    }

    #[test]
    fn percent_and_eta_are_arithmetic_and_a_zero_rate_has_no_eta() {
        let p = prog(276, 314, 239);
        assert_eq!(percent(&p), Some(53));
        // 276 open at 239 per 28 days: 32.3 days, rounded up.
        assert_eq!(eta_days(&p), Some(33));
        assert_eq!(eta_days(&prog(10, 0, 0)), None, "no closes, no guess");
        assert_eq!(eta_days(&prog(0, 5, 0)), Some(0), "nothing open");
        assert_eq!(percent(&prog(0, 0, 0)), None);
        assert_eq!(
            percent(&prog(1, 199, 0)),
            Some(99),
            "100 only when nothing is left"
        );
    }

    fn st(name: &str, closed_7d: u32) -> Stats {
        Stats {
            profile: "personal".into(),
            name: name.into(),
            version: Some("v0.0.1".into()),
            progress: Progress {
                closed_7d,
                ..prog(4, 4, 4)
            },
            ..Stats::default()
        }
    }

    fn item(slug: &str, state: State, project: &str, from: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            state,
            project: project.into(),
            task: format!("Do {slug}."),
            from: from.map(String::from),
            ..Default::default()
        }
    }

    #[test]
    fn queue_items_join_by_board_origin_name_or_one_repo_and_the_rest_are_unlinked() {
        let stats = [
            st("agent-runtime", 1),
            st("notes-cockpit", 9),
            st("trader", 0),
        ];
        let repos: HashMap<String, String> = [
            ("agent-runtime", "dotfiles"),
            ("notes-cockpit", "dotfiles"),
            ("trader", "freqtrade"),
        ]
        .into_iter()
        .map(|(a, b)| (a.into(), b.into()))
        .collect();
        let q = Queue {
            items: vec![
                item(
                    "a",
                    State::Running,
                    "dotfiles",
                    Some("board:agent-runtime:row"),
                ),
                item("b", State::Running, "trader", None),
                item("c", State::Waiting, "freqtrade", None),
                item("d", State::Queued, "dotfiles", None),
                item("e", State::Done, "trader", None),
            ],
            ..Queue::default()
        };
        let feed = Feed {
            projects: vec![Project {
                profile: "personal".into(),
                project: "trader".into(),
                inbox: 2,
                ..Project::default()
            }],
            rows: vec![Row {
                profile: "personal".into(),
                project: Some("trader".into()),
                requested: true,
                ..Row::default()
            }],
            ..Feed::default()
        };
        let p = build(&stats, Some(&feed), &json!({}), Some(&q), &repos);
        let names: Vec<&str> = p.cards.iter().map(|c| c.name.as_str()).collect();
        // trader runs one and waits one; agent-runtime runs one; notes-cockpit closed most.
        assert_eq!(names, ["trader", "agent-runtime", "notes-cockpit"]);
        let trader = &p.cards[0];
        assert_eq!(
            (trader.running.len(), trader.waiting, trader.queued),
            (1, 1, 0)
        );
        assert_eq!((trader.inbox, trader.requested), (2, 1));
        assert_eq!(p.cards[1].running[0].slug, "a");
        assert_eq!(
            p.unlinked,
            ["dotfiles: Do d"],
            "two lab projects share dotfiles"
        );
        assert!(p.cards[0].in_flight() && !p.cards[2].in_flight());
    }

    #[test]
    fn repos_read_the_registry_and_skip_entries_without_one() {
        let map = r#"{"trackers": {"agent-runtime": {"repo": "dotfiles"}, "home-config": {"lab": "personal"}, "x": "y"}}"#;
        let r = repos(map);
        assert_eq!(r.len(), 1);
        assert_eq!(r["agent-runtime"], "dotfiles");
        assert!(repos("not json").is_empty());
    }

    #[test]
    fn the_summary_line_says_the_numbers_and_why_an_eta_is_missing() {
        let mut c = Card {
            version: Some("v0.0.1".into()),
            progress: prog(276, 314, 239),
            ..Card::default()
        };
        c.progress.closed_7d = 103;
        c.percent = percent(&c.progress);
        c.eta_days = eta_days(&c.progress);
        assert_eq!(
            summary(&c),
            "v0.0.1 53% (314 of 590 by size), 7d 103, 28d 239, ETA 33d"
        );
        c.eta_days = None;
        assert!(summary(&c).ends_with("no ETA (no closes in 28d)"));
    }
}
