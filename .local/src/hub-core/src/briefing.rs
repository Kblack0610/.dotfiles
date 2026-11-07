//! The briefing: what needs the human, then one line per area (Infra, Sessions, Workers
//! overnight, Nightly, Delivery, Costs), then the detail. `hub briefing --md` writes it for
//! `agentctl-briefing`; `--json` is the same document for a surface.
//!
//! It composes the readers that already exist and adds no ranking of its own: Needs you is
//! Home's `needs` (the one ranking), folded by kind so nine asks take one line, not five. `build`
//! is pure over `Inputs`, and `gather` reads them. Each area is a level, one sentence, at most
//! `DETAILS_MAX` detail lines and the tab that owns the fact. A source that could not be read is
//! said in the headline's next line, never left to read as an all-clear (comms-standard).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{Local, TimeZone};
use serde::Serialize;
use serde_json::Value;

use crate::capacity::clock;
use crate::costs::{Call, Live};
use crate::fleet::runner::Watch;
use crate::home::{self, Home, Kind, Need};
use crate::jobs::{self, Job};
use crate::queue::money;
use crate::queue::{self, Item, Queue, State};
use crate::text::{age, cap};

/// Needs you holds at most this many items; past it, one less and a "more" line
/// (`channels.toml [channel.briefing]`).
pub const NEEDS_SHOWN: usize = 5;
/// How long one Needs you item may be (the same channel's cap).
pub const ITEM_MAX: usize = 160;
/// How long one Areas line may be.
pub const AREA_MAX: usize = 200;
/// Detail lines an area keeps.
pub const DETAILS_MAX: usize = 3;
/// Days before yesterday that the averages are over.
pub const AVG_DAYS: usize = 7;
/// A stalled session counts as stuck past this idle time.
pub const STALL_MIN: i64 = 120;
/// Yesterday's spend over the average by this ratio is warn, by `BAD_RATIO` bad.
pub const WARN_RATIO: f64 = 1.25;
pub const BAD_RATIO: f64 = 1.5;
/// The Lazer pool past this share of its cap is warn.
pub const LAZER_WARN: f64 = 0.9;
/// The runners whose overnight pass the Nightly area reports; Workers counts them too.
pub const NIGHTLY_RUNNERS: [&str; 2] = ["dream", "nightly-sync"];
/// The briefing's own runner, left out of what it reports.
const SELF: &str = "briefing";
/// The window when `--since` is not given.
pub const DEFAULT_WINDOW_SECS: i64 = 12 * 3600;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    #[default]
    Ok,
    Warn,
    Bad,
}

impl Level {
    pub fn word(self) -> &'static str {
        match self {
            Level::Ok => "ok",
            Level::Warn => "warn",
            Level::Bad => "bad",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Area {
    pub name: &'static str,
    pub level: Level,
    pub line: String,
    pub details: Vec<String>,
    /// The hub tab that owns the fact (`layout.rs` ids), with its filter when it has one.
    pub link: &'static str,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Briefing {
    pub at: i64,
    pub since: i64,
    pub headline: String,
    pub needs: Vec<String>,
    pub areas: Vec<Area>,
    /// Markdown lines under `## Details`.
    pub details: Vec<String>,
    /// What could not be read.
    pub errors: Vec<String>,
}

/// What `build` reads. None is a source that could not be read; its reason is in `errors`.
#[derive(Default)]
pub struct Inputs {
    pub now: i64,
    pub since: i64,
    pub home: Home,
    /// fleet-sessions' state with the live asks and signals (`boards::state`).
    pub state: Value,
    pub queue: Option<Queue>,
    pub watches: Option<Vec<Watch>>,
    /// The machine's issues, from the newest system-health report written in the window.
    pub host: Vec<String>,
    /// agentctl runs that finished in the window.
    pub runs: Option<Vec<Job>>,
    /// agentctl calls made in the window.
    pub calls: Option<Vec<Call>>,
    /// day-log records of the days before today, oldest first.
    pub days: Vec<(String, Value)>,
    /// Queue items finished in the window.
    pub done: Option<Vec<Item>>,
    pub live: Option<Live>,
    /// comms' one-line inbox summary.
    pub mail_stats: Option<String>,
    pub errors: Vec<String>,
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// The local date `days` before the one holding `t`, `YYYY-MM-DD`.
fn date_before(t: i64, days: i64) -> String {
    Local
        .timestamp_opt(t - days * 86_400, 0)
        .single()
        .map_or_else(String::new, |d| d.format("%Y-%m-%d").to_string())
}

/// Up to `n` names, then "and N more".
fn names(all: &[String], n: usize) -> String {
    let mut s = all.iter().take(n).cloned().collect::<Vec<_>>().join(", ");
    if all.len() > n {
        s += &format!(" and {} more", all.len() - n);
    }
    s
}

/// One Needs you line for a row.
fn need_line(n: &Need, now: i64) -> String {
    let waited = n.since.map(|s| age(now - s));
    let text = n.text.trim_end_matches('.');
    match n.kind {
        Kind::Ask => {
            let mut meta: Vec<String> = vec![];
            meta.extend((!n.project.is_empty()).then(|| n.project.clone()));
            meta.extend(waited);
            meta.extend(n.recommend.as_ref().map(|r| format!("recommend {r}")));
            let meta = if meta.is_empty() {
                String::new()
            } else {
                format!(" ({})", meta.join(", "))
            };
            format!("Answer ask {}: {text}{meta}.", n.id)
        }
        Kind::Session => format!(
            "Session {} needs you: {text}{}.",
            home::tmux_name(&n.id),
            waited.map_or_else(String::new, |w| format!(" ({w})"))
        ),
        Kind::Queue => format!("Queue item {} waits on you: {text}.", n.id),
        Kind::Sheet => format!("From your sheet ({}): {text}.", n.project),
        _ => format!("{text}."),
    }
}

/// Several rows of one kind as one line: how many, and the top one.
fn group_line(kind: Kind, rows: &[&Need], now: i64) -> String {
    let n = rows.len();
    let top = need_line(rows[0], now);
    let ids = |f: &dyn Fn(&Need) -> String| rows.iter().map(|r| f(r)).collect::<Vec<_>>();
    match kind {
        Kind::Ask => {
            let held = rows.iter().filter(|r| r.target.is_some()).count();
            format!(
                "{} wait on you, {held} holding up a session. Top: {top}",
                plural(n, "ask", "asks")
            )
        }
        Kind::Session => format!("{n} sessions need you. Top: {top}"),
        Kind::Queue => format!("{n} queue items wait on you. Top: {top}"),
        Kind::Sheet => format!("{n} rows of your sheet need you. Top: {top}"),
        Kind::Budget => format!(
            "{n} runners stopped at their budget: {}. To go on today: agentctl budget <name> raise <usd>.",
            names(&ids(&|r| r.id.trim_start_matches("budget:").to_string()), 3)
        ),
        Kind::Night => format!(
            "{n} night tasks failed: {}. Run agent-queue show <slug>.",
            names(&ids(&|r| r.id.clone()), 3)
        ),
        Kind::Mail => format!("{n} critical mail threads. Top: {top}"),
        _ => format!("{n} more like this. Top: {top}"),
    }
}

/// Needs you: Home's ranking folded by kind, in the order each kind first ranks. Nightly and
/// red-now rows are left to the Nightly and Infra areas, which carry them with their ages.
/// The count is of the folded items before the cap, the "N things" the headline says.
pub fn needs(rows: &[Need], now: i64) -> (usize, Vec<String>) {
    let rows: Vec<&Need> = rows
        .iter()
        .filter(|n| !matches!(n.kind, Kind::Nightly | Kind::Red))
        .collect();
    let mut order: Vec<Kind> = vec![];
    let mut by: BTreeMap<Kind, Vec<&Need>> = BTreeMap::new();
    for r in &rows {
        if !by.contains_key(&r.kind) {
            order.push(r.kind);
        }
        by.entry(r.kind).or_default().push(r);
    }
    let mut lines: Vec<String> = order
        .iter()
        .flat_map(|k| {
            let g = &by[k];
            // The janitor's and a stopped dispatch's lines each say their own thing.
            if g.len() == 1 || matches!(k, Kind::Stopped | Kind::Janitor) {
                g.iter().map(|r| need_line(r, now)).collect::<Vec<_>>()
            } else {
                vec![group_line(*k, g, now)]
            }
        })
        .map(|l| cap(&l, ITEM_MAX))
        .collect();
    let n = lines.len();
    if n > NEEDS_SHOWN {
        let more = lines.len() - (NEEDS_SHOWN - 1);
        lines.truncate(NEEDS_SHOWN - 1);
        lines.push(format!(
            "{more} more on Home: run hub needs, or open the Home tab."
        ));
    }
    (n, lines)
}

fn infra(i: &Inputs) -> Area {
    let mut level = Level::Ok;
    let mut parts: Vec<String> = vec![];
    let mut details: Vec<String> = vec![];
    match &i.watches {
        None => {
            level = Level::Warn;
            parts.push("the watches could not be read".into());
        }
        Some(ws) => {
            let green = ws.iter().filter(|w| w.state == "OK").count();
            parts.push(format!("{green} of {} watches green", ws.len()));
            let (new, stale): (Vec<&Watch>, Vec<&Watch>) = ws
                .iter()
                .filter(|w| matches!(w.state.as_str(), "TRIP" | "ERROR"))
                .partition(|w| w.since.is_some_and(|s| s >= i.since));
            if !new.is_empty() {
                let loud = new
                    .iter()
                    .any(|w| matches!(w.severity.as_str(), "high" | "urgent"));
                level = level.max(if loud { Level::Bad } else { Level::Warn });
                parts.push(format!(
                    "{} since {}",
                    plural(new.len(), "new trip", "new trips"),
                    clock(i.since)
                ));
                details.extend(new.iter().map(|w| {
                    let what = if w.state == "ERROR" {
                        "cannot check"
                    } else {
                        "tripped"
                    };
                    let at = w
                        .since
                        .map_or_else(String::new, |s| format!(" at {}", clock(s)));
                    format!("{} {what}{at}", w.name)
                }));
            }
            if !stale.is_empty() {
                let named: Vec<String> = stale
                    .iter()
                    .map(|w| match w.since {
                        Some(s) => format!("{} {}", w.name, age(i.now - s)),
                        None => w.name.clone(),
                    })
                    .collect();
                parts.push(format!(
                    "{} ({})",
                    plural(stale.len(), "stale red", "stale reds"),
                    names(&named, 3)
                ));
            }
        }
    }
    let chips: Vec<String> = i
        .home
        .exceptions()
        .map(|c| {
            level = level.max(match c.level {
                home::Level::Red => Level::Bad,
                _ => Level::Warn,
            });
            let word = match c.level {
                home::Level::Red => "red",
                home::Level::Warn => "warn",
                _ => "no data",
            };
            format!("{} {word}", c.name)
        })
        .collect();
    if !chips.is_empty() {
        parts.push(format!("domains {}", chips.join(", ")));
    }
    if !i.host.is_empty() {
        level = level.max(Level::Warn);
        parts.push(format!(
            "this machine has {}",
            plural(i.host.len(), "issue", "issues")
        ));
        details.push(format!("This machine: {}", i.host.join(", ")));
    }
    Area {
        name: "Infra",
        level,
        line: parts.join("; "),
        details,
        link: "#infra",
    }
}

fn sessions(i: &Inputs) -> Area {
    if i.state.is_null() {
        return Area {
            name: "Sessions",
            level: Level::Warn,
            line: "no fleet state yet".into(),
            details: vec![],
            link: "#sessions",
        };
    }
    let c = &i.state["counts"];
    let n = |k: &str| c[k].as_u64().unwrap_or(0);
    let mut line = format!(
        "{} working, {} need you, {} stalled",
        n("WORKING"),
        n("NEEDS"),
        n("STALLED")
    );
    let items: &[Item] = i.queue.as_ref().map_or(&[], |q| &q.items);
    let stuck: Vec<(String, i64)> = i.state["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|s| s["bucket"] == "STALLED")
        .filter_map(|s| {
            let idle = s["idle_min"].as_i64().filter(|m| *m >= STALL_MIN)?;
            let tmux = home::tmux_name(s["target"].as_str().unwrap_or(""));
            let name = items
                .iter()
                .find(|it| {
                    it.state == State::Running
                        && it
                            .session
                            .as_deref()
                            .is_some_and(|x| home::tmux_name(x) == tmux)
                })
                .map_or_else(|| tmux.to_string(), |it| it.slug.clone());
            Some((name, idle))
        })
        .collect();
    let level = if stuck.is_empty() {
        Level::Ok
    } else {
        let named: Vec<String> = stuck.iter().map(|(n, _)| n.clone()).collect();
        line += &format!(
            "; {} over {}h ({})",
            plural(stuck.len(), "stalled", "stalled"),
            STALL_MIN / 60,
            names(&named, 3)
        );
        Level::Warn
    };
    Area {
        name: "Sessions",
        level,
        line,
        details: stuck
            .iter()
            .map(|(n, m)| format!("{n} idle {}", age(m * 60)))
            .collect(),
        link: "#sessions",
    }
}

/// Each runner's newest run in the window, by name.
fn newest(runs: &[Job]) -> BTreeMap<&str, &Job> {
    let mut m: BTreeMap<&str, &Job> = BTreeMap::new();
    for j in runs.iter().filter(|j| j.name != SELF) {
        let e = m.entry(j.name.as_str()).or_insert(j);
        if j.finished > e.finished {
            *e = j;
        }
    }
    m
}

/// What the calls cost, $0 for none.
fn spent_in(calls: &[Call]) -> f64 {
    // Not sum(): an empty f64 sum is -0.0, which prints as "$-0.00".
    calls.iter().filter_map(|c| c.cost).fold(0.0, |a, c| a + c)
}

fn budget_stops(state: &Value) -> Vec<String> {
    state["budget"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|b| b["runner"].as_str().map(String::from))
        .collect()
}

fn workers(i: &Inputs) -> Area {
    let Some(runs) = &i.runs else {
        return Area {
            name: "Workers overnight",
            level: Level::Warn,
            line: "the runner ledger could not be read".into(),
            details: vec![],
            link: "#fleet",
        };
    };
    let last = newest(runs);
    let failed: Vec<&&Job> = last.values().filter(|j| j.ok == Some(false)).collect();
    let stops = budget_stops(&i.state);
    // A run that ended BLOCKED (a gate or a budget) did not do its work: not ok, not failed.
    let blocked: Vec<String> = last
        .values()
        .filter(|j| j.ok.is_none() && !stops.contains(&j.name))
        .map(|j| j.name.clone())
        .collect();
    let not_ok = last.values().filter(|j| j.ok != Some(true)).count();
    let mut line = if last.is_empty() {
        format!("no runner ran since {}", clock(i.since))
    } else {
        format!("{} of {} ok", last.len() - not_ok, last.len())
    };
    if let Some(calls) = &i.calls {
        let spent: f64 = spent_in(calls);
        line += &format!(", {}", money(spent));
    }
    let mut level = Level::Ok;
    if !failed.is_empty() {
        level = Level::Bad;
        let named: Vec<String> = failed
            .iter()
            .map(|j| format!("{} {}", j.name, j.finished.map(clock).unwrap_or_default()))
            .collect();
        line += &format!(". Failed: {}", names(&named, 3));
    }
    if !stops.is_empty() {
        level = level.max(Level::Warn);
        line += &format!(". Budget stop: {}", names(&stops, 3));
    }
    if !blocked.is_empty() {
        level = level.max(Level::Warn);
        line += &format!(". Blocked: {}", names(&blocked, 3));
    }
    Area {
        name: "Workers overnight",
        level,
        line,
        details: failed
            .iter()
            .map(|j| {
                format!(
                    "{} ended {} at {}",
                    j.name,
                    j.result,
                    j.finished.map(clock).unwrap_or_default()
                )
            })
            .collect(),
        link: if failed.is_empty() {
            "#fleet"
        } else {
            "#fleet?s=failed"
        },
    }
}

fn nightly(i: &Inputs) -> Area {
    let mut level = Level::Ok;
    let mut ok: Vec<String> = vec![];
    let mut not: Vec<String> = vec![];
    let last = i.runs.as_deref().map(newest);
    for r in NIGHTLY_RUNNERS {
        match last.as_ref().map(|m| m.get(r)) {
            None => {
                level = level.max(Level::Warn);
                not.push(format!("{r} unknown"));
            }
            Some(None) => {
                level = level.max(Level::Warn);
                not.push(format!("{r} did not run"));
            }
            Some(Some(j)) if j.ok == Some(false) => {
                level = Level::Bad;
                not.push(format!("{r} {}", j.result.to_lowercase()));
            }
            Some(Some(j)) if j.ok.is_none() => {
                level = level.max(Level::Warn);
                not.push(format!("{r} {}", j.result.to_lowercase()));
            }
            Some(Some(_)) => ok.push(r.to_string()),
        }
    }
    let yesterday = date_before(i.now, 1);
    if i.days.iter().any(|(d, _)| *d == yesterday) {
        ok.push("day-log".into());
    } else {
        level = level.max(Level::Warn);
        not.push("day-log has no record for yesterday".into());
    }
    let mut details = vec![];
    let reds: Vec<String> = i.state["main"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|m| {
            details.push(cap(m["reason"].as_str().unwrap_or(""), AREA_MAX - 4));
            format!("{} red", m["repo"].as_str().unwrap_or("?"))
        })
        .collect();
    if !reds.is_empty() {
        level = Level::Bad;
    }
    let mut parts = vec![];
    if !ok.is_empty() {
        parts.push(format!("{} ok", ok.join(", ")));
    }
    parts.extend(not);
    parts.extend(reds);
    Area {
        name: "Nightly",
        level,
        line: parts.join("; "),
        details,
        link: "#infra",
    }
}

/// The record for yesterday and the mean of `f` over up to `AVG_DAYS` days before it.
fn yesterday_and_avg(
    i: &Inputs,
    f: impl Fn(&Value) -> Option<f64>,
) -> Option<(&Value, Option<f64>)> {
    let yesterday = date_before(i.now, 1);
    let at = i.days.iter().position(|(d, _)| *d == yesterday)?;
    let before: Vec<f64> = i.days[..at]
        .iter()
        .rev()
        .take(AVG_DAYS)
        .filter_map(|(_, r)| f(r))
        .collect();
    let avg = (!before.is_empty()).then(|| before.iter().sum::<f64>() / before.len() as f64);
    Some((&i.days[at].1, avg))
}

fn merged(r: &Value) -> Option<f64> {
    r["merged"].as_array().map(|a| a.len() as f64)
}

fn spent(r: &Value) -> Option<f64> {
    r["usage"]
        .as_array()?
        .iter()
        .find(|u| u["project"] == "TOTAL")?["cost_usd"]
        .as_f64()
}

fn delivery(i: &Inputs) -> Area {
    let mut level = Level::Ok;
    let mut parts = vec![];
    match yesterday_and_avg(i, merged) {
        None => {
            level = Level::Warn;
            parts.push("no day-log record for yesterday".into());
        }
        Some((rec, avg)) => {
            let row = crate::boards::day_row("", rec);
            let mut s = format!(
                "{} merged yesterday in {}",
                plural(row.merged, "PR", "PRs"),
                plural(row.repos, "repo", "repos")
            );
            if let Some(a) = avg {
                s += &format!(" (avg {a:.0})");
                if (row.merged as f64) < a / 2.0 {
                    level = Level::Warn;
                }
            }
            parts.push(s);
        }
    }
    let mut details = vec![];
    match &i.done {
        None => {
            level = level.max(Level::Warn);
            parts.push("the queue could not be read".into());
        }
        Some(done) => {
            let failed: Vec<&Item> = done
                .iter()
                .filter(|it| it.status.as_deref() == Some("failed"))
                .collect();
            let ok = done
                .iter()
                .filter(|it| it.status.as_deref() == Some("ok"))
                .count();
            let mut s = format!(
                "{} done since {}",
                plural(ok, "queue item", "queue items"),
                clock(i.since)
            );
            if !failed.is_empty() {
                level = level.max(Level::Warn);
                s += &format!(", {} failed", failed.len());
                details.extend(
                    failed
                        .iter()
                        .map(|it| format!("{} ({}) failed: {}", it.slug, it.project, it.title())),
                );
            }
            parts.push(s);
        }
    }
    Area {
        name: "Delivery",
        level,
        line: parts.join("; "),
        details,
        link: "#queue",
    }
}

fn costs(i: &Inputs) -> Area {
    let mut level = Level::Ok;
    let mut parts = vec![];
    match yesterday_and_avg(i, spent) {
        Some((rec, avg)) if spent(rec).is_some() => {
            let y = spent(rec).unwrap_or(0.0);
            let mut s = format!("{} yesterday", money(y));
            if let Some(a) = avg.filter(|a| *a > 0.0) {
                let pct = (y / a - 1.0) * 100.0;
                s += &format!(" (avg {}, {pct:+.0}%)", money(a));
                if y > a * BAD_RATIO {
                    level = Level::Bad;
                } else if y > a * WARN_RATIO {
                    level = Level::Warn;
                }
            }
            parts.push(s);
        }
        _ => {
            level = Level::Warn;
            parts.push("no spend for yesterday in day-log".into());
        }
    }
    if let Some(calls) = &i.calls {
        let r: f64 = spent_in(calls);
        parts.push(format!("runners {} since {}", money(r), clock(i.since)));
    }
    match i
        .live
        .as_ref()
        .and_then(|l| l.lazer_spend.zip(l.lazer_budget))
    {
        Some((s, b)) => {
            if b > 0.0 && s >= b * LAZER_WARN {
                level = level.max(Level::Warn);
            }
            parts.push(format!("Lazer {} of {}", money(s), money(b)));
        }
        None => parts.push("Lazer unknown".into()),
    }
    Area {
        name: "Costs",
        level,
        line: parts.join(", "),
        details: vec![],
        link: "#costs",
    }
}

fn headline(i: &Inputs, n: usize) -> String {
    let when = day_clock(i.now);
    let needs = match n {
        0 => "nothing needs you".to_string(),
        1 => "1 thing needs you".to_string(),
        n => format!("{n} things need you"),
    };
    let mut s = format!("As of {when}: {needs}.");
    if let Some((rec, avg)) = yesterday_and_avg(i, spent) {
        let row = crate::boards::day_row("", rec);
        s += &format!(
            " Yesterday {} in {}",
            plural(row.merged, "PR", "PRs"),
            plural(row.repos, "repo", "repos")
        );
        if let Some(y) = spent(rec) {
            s += &format!(", {} spent", money(y));
            if let Some(a) = avg {
                s += &format!(" ({AVG_DAYS}-day avg {})", money(a));
            }
        }
        s.push('.');
    }
    s
}

/// The per-runner overnight table and the lines no area carries.
fn details(i: &Inputs, areas: &[Area]) -> Vec<String> {
    let mut out = vec![];
    for a in areas.iter().filter(|a| !a.details.is_empty()) {
        out.push(format!("### {}", a.name));
        out.push(String::new());
        out.extend(
            a.details
                .iter()
                .take(DETAILS_MAX)
                .map(|d| format!("- {}", cap(d, AREA_MAX - 2))),
        );
        if a.details.len() > DETAILS_MAX {
            out.push(format!("- and {} more", a.details.len() - DETAILS_MAX));
        }
        out.push(String::new());
    }
    if let Some(runs) = &i.runs {
        let last = newest(runs);
        if !last.is_empty() {
            let mut count: BTreeMap<&str, usize> = BTreeMap::new();
            for j in runs.iter().filter(|j| j.name != SELF) {
                *count.entry(j.name.as_str()).or_default() += 1;
            }
            let mut cost: BTreeMap<&str, f64> = BTreeMap::new();
            for c in i.calls.iter().flatten() {
                *cost.entry(c.runner.as_str()).or_default() += c.cost.unwrap_or(0.0);
            }
            out.push(format!("### Runners since {}", clock(i.since)));
            out.push(String::new());
            out.push("| Runner | Runs | Last | Ended | Spent |".into());
            out.push("|---|---|---|---|---|".into());
            for (name, j) in &last {
                out.push(format!(
                    "| {name} | {} | {} | {} | {} |",
                    count[name],
                    j.finished.map(clock).unwrap_or_default(),
                    j.result,
                    cost.get(name).map_or_else(|| "-".into(), |c| money(*c))
                ));
            }
            out.push(String::new());
        }
    }
    let mut also = vec![];
    if let Some(ws) = &i.watches {
        let back: Vec<String> = ws
            .iter()
            .filter(|w| w.state == "OK" && w.since.is_some_and(|s| s >= i.since))
            .map(|w| w.name.clone())
            .collect();
        if !back.is_empty() {
            also.push(format!(
                "Back to OK since {}: {}.",
                clock(i.since),
                names(&back, 6)
            ));
        }
    }
    if let Some(m) = &i.mail_stats {
        also.push(format!("Email: {}.", m.trim().trim_end_matches('.')));
    }
    if !also.is_empty() {
        out.push("### Also".into());
        out.push(String::new());
        out.extend(also.iter().map(|l| format!("- {}", cap(l, AREA_MAX - 2))));
        out.push(String::new());
    }
    if !i.errors.is_empty() || !i.home.errors.is_empty() {
        out.push("### Could not read".into());
        out.push(String::new());
        out.extend(
            i.home
                .errors
                .iter()
                .chain(&i.errors)
                .map(|e| format!("- {}", cap(e, AREA_MAX - 2))),
        );
        out.push(String::new());
    }
    while out.last().is_some_and(String::is_empty) {
        out.pop();
    }
    out
}

pub fn build(i: &Inputs) -> Briefing {
    let (n, needs) = needs(&i.home.needs, i.now);
    let areas = vec![
        infra(i),
        sessions(i),
        workers(i),
        nightly(i),
        delivery(i),
        costs(i),
    ];
    Briefing {
        at: i.now,
        since: i.since,
        headline: headline(i, n),
        needs,
        details: details(i, &areas),
        areas,
        errors: i.home.errors.iter().chain(&i.errors).cloned().collect(),
    }
}

impl Briefing {
    /// The file `agentctl-briefing` writes: headline, Needs you, Areas, then Details.
    /// notes-cli's Morning block reads the `As of ` line and the `- ` items under Needs you.
    pub fn markdown(&self) -> String {
        let mut s = String::from("---\ngenerated: true\n---\n\n# Briefing\n\n");
        s += &self.headline;
        s += "\n\n";
        if !self.errors.is_empty() {
            let line = format!(
                "Could not read {}, so this may be missing items: see Details.",
                plural(self.errors.len(), "source", "sources")
            );
            s += &line;
            s += "\n\n";
        }
        s += "## Needs you\n\n";
        if self.needs.is_empty() {
            s += "- nothing\n";
        }
        for n in &self.needs {
            s += &format!("- {n}\n");
        }
        s += "\n## Areas\n\n";
        for a in &self.areas {
            let line = format!("{}: {}, {}", a.name, a.level.word(), a.line);
            s += &format!("- {}\n", cap(&line, AREA_MAX - 2));
        }
        if !self.details.is_empty() {
            s += "\n## Details\n\n";
            s += &self.details.join("\n");
            s += "\n";
        }
        s
    }
}

/// Home's "Since last night" starts this long before today's local midnight (18:00 the evening
/// before), so the evening's runs count at any hour of the day.
const NIGHT_FROM_SECS: i64 = 6 * 3600;
/// How often both surfaces re-read "Since last night": it composes the runs, calls, day records
/// and Prometheus, none of them watched, so it is read on this cadence while Home is shown.
pub const NIGHT_REFRESH: std::time::Duration = std::time::Duration::from_secs(60);
/// Where "Queue a fix" queues a bad area: every area is the fleet's own machinery.
pub const FIX_PROJECT: &str = "agent-runtime";

/// When Home's "Since last night" window starts for `now`.
fn last_night(now: i64) -> i64 {
    crate::text::local_day_start(now) - NIGHT_FROM_SECS
}

/// One row of "Since last night": an area that is not ok, and for a bad one the task "Queue a
/// fix" queues.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct NightRow {
    #[serde(flatten)]
    pub area: Area,
    pub fix: Option<Fix>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Fix {
    pub project: &'static str,
    pub task: String,
    /// The open queue item already carrying this area's fix for this window, so neither
    /// surface, nor a reload, queues it twice.
    pub queued: Option<String>,
}

/// Home's "Since last night" section on both surfaces (dashboards rules 4 and 8): the areas
/// that are not ok in the briefing's order, the ok ones folded into one line, and what this
/// read could not reach (Home's own errors are Home's to show).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Night {
    pub at: i64,
    pub since: i64,
    /// "Thu 18:00": when the window starts.
    pub since_label: String,
    pub rows: Vec<NightRow>,
    /// "Infra, Delivery, Costs ok", "all 6 areas ok", or empty when none is.
    pub ok_line: String,
    pub errors: Vec<String>,
}

/// The task a bad area queues: what it says, its detail and the tab that has the facts.
pub fn fix_task(a: &Area, since: i64) -> String {
    let mut s = format!("{} {}.", fix_head(a.name, since), a.line);
    if !a.details.is_empty() {
        s += &format!(" Detail: {}.", a.details.join("; "));
    }
    s += &format!(
        " The facts are on the hub's {} tab. Find the cause and fix it; if it is already fixed, close this with the proof.",
        a.link
    );
    s
}

/// What every fix task for area `name` in the window from `since` starts with.
fn fix_head(name: &str, since: i64) -> String {
    format!(
        "Fix what the briefing's {name} area reads bad since {}:",
        day_clock(since)
    )
}

fn day_clock(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map_or_else(String::new, |d| d.format("%a %H:%M").to_string())
}

/// The briefing over `i`, cut to Home's section.
pub fn night(i: &Inputs) -> Night {
    let b = build(i);
    let (ok, rows): (Vec<Area>, Vec<Area>) =
        b.areas.into_iter().partition(|a| a.level == Level::Ok);
    let ok_line = match (ok.len(), rows.is_empty()) {
        (0, _) => String::new(),
        (n, true) => format!("all {n} areas ok"),
        _ => format!(
            "{} ok",
            ok.iter().map(|a| a.name).collect::<Vec<_>>().join(", ")
        ),
    };
    let queued = |name: &str| {
        let head = fix_head(name, i.since);
        i.queue.as_ref().and_then(|q| {
            q.items
                .iter()
                .find(|it| it.state != queue::State::Done && it.task.starts_with(&head))
                .map(|it| it.slug.clone())
        })
    };
    Night {
        at: i.now,
        since: i.since,
        since_label: day_clock(i.since),
        rows: rows
            .into_iter()
            .map(|a| NightRow {
                fix: (a.level == Level::Bad).then(|| Fix {
                    project: FIX_PROJECT,
                    task: fix_task(&a, i.since),
                    queued: queued(a.name),
                }),
                area: a,
            })
            .collect(),
        ok_line,
        errors: i.errors.clone(),
    }
}

/// The newest `system-health-*.md` written at or after `since`: its "## Issues Detected"
/// bullets, each without its "-> do:" hint.
pub fn host_issues(dir: &Path, since: i64) -> Vec<String> {
    let newest = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("system-health-") && n.ends_with(".md"))
        })
        .max();
    let Some(f) = newest else { return vec![] };
    let fresh = std::fs::metadata(&f)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .is_some_and(|d| d.as_secs() as i64 >= since);
    if !fresh {
        return vec![];
    }
    let text = std::fs::read_to_string(&f).unwrap_or_default();
    issues(&text)
}

/// A system-health report's "## Issues Detected" bullets.
pub fn issues(md: &str) -> Vec<String> {
    md.lines()
        .skip_while(|l| !l.starts_with("## Issues Detected"))
        .skip(1)
        .take_while(|l| !l.starts_with("## "))
        .filter_map(|l| l.strip_prefix("- "))
        .map(|l| l.split(" -> do: ").next().unwrap_or(l).trim().to_string())
        .collect()
}

fn env_dir(k: &str, home: &Path, d: &str) -> PathBuf {
    std::env::var_os(k)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(d))
}

/// Every input, read now for the window from `since`.
pub fn gather(since: i64, now: i64) -> Inputs {
    gather_from(since, now, || {
        let (state, queue, board, infra) = home::gather(true);
        let home = home::build(&state, Some(&queue), Some(&board), infra.as_ref());
        (state, queue, home)
    })
}

/// Home's "Since last night" for a caller that has read Home already (agent-web caches its
/// infra, the hub TUI holds the fleet state and the queue), so nothing is read twice.
pub fn since_last_night(now: i64, state: Value, queue: Queue, home: Home) -> Night {
    night(&gather_from(last_night(now), now, || (state, queue, home)))
}

/// The inputs, with Home's from `home`, which runs beside the done list and the Prometheus read.
fn gather_from(since: i64, now: i64, home: impl FnOnce() -> (Value, Queue, Home)) -> Inputs {
    use crate::session_actions::System;
    let home_dir = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let mut errors = vec![];
    let (state, queue, home, done, live) = std::thread::scope(|s| {
        let live = s.spawn(|| {
            crate::prom::base()
                .and_then(|b| crate::prom::instant(&b, &crate::costs::live_q()))
                .map(|series| crate::costs::live(&series).0)
        });
        let done = s.spawn(move || {
            queue::list_since(&System, "done", &date_before(since, 0)).map(|items| {
                items
                    .into_iter()
                    .filter(|it| {
                        it.finished
                            .as_deref()
                            .and_then(crate::fleet::ts)
                            .is_some_and(|f| f >= since)
                    })
                    .collect::<Vec<_>>()
            })
        });
        let (state, queue, home) = home();
        (
            state,
            queue,
            home,
            done.join().unwrap_or_else(|_| Err("panicked".into())),
            live.join().unwrap_or_else(|_| Err("panicked".into())),
        )
    });
    let done = done
        .map_err(|e| errors.push(format!("agent-queue list --since: {e}")))
        .ok();
    let live = live
        .map_err(|e| errors.push(format!("Lazer spend: {e}")))
        .ok();

    let (wdir, wstate) = crate::fleet::runner::watch_dirs(&home_dir.to_string_lossy(), |k| {
        std::env::var(k).unwrap_or_default()
    });
    let watches = crate::fleet::runner::watches(&wdir, &wstate)
        .map_err(|e| errors.push(format!("watches: {e}")))
        .ok();

    let (runs, run_errors) = jobs::agentctl_runs(&jobs::Paths::from_env(), since);
    let runs = runs
        .into_iter()
        .filter(|j| j.state == jobs::State::Done)
        .collect();
    errors.extend(run_errors);

    let calls_path = crate::fleet::Paths::from_env().calls;
    let calls = std::fs::read_to_string(&calls_path)
        .map(|t| crate::costs::calls(&t, since))
        .map_err(|e| errors.push(format!("{}: {e}", calls_path.display())))
        .ok();

    let today = date_before(now, 0);
    let dir = crate::boards::daylog_dir();
    let all: Vec<String> = crate::boards::days(&dir)
        .into_iter()
        .filter(|d| *d < today)
        .collect();
    let days = all[all.len().saturating_sub(AVG_DAYS + 1)..]
        .iter()
        .filter_map(|d| crate::boards::record(&dir, Some(d)).map(|r| (d.clone(), r)))
        .collect();

    let comms = crate::signals::Paths::from_env().comms;
    Inputs {
        now,
        since,
        state,
        queue: Some(queue),
        watches,
        host: host_issues(
            &env_dir("BRIEFING_HEALTH_DIR", &home_dir, ".cache/system-health"),
            since,
        ),
        runs: Some(runs),
        calls,
        days,
        done,
        live,
        mail_stats: std::fs::read_to_string(comms.join("stats-summary.txt"))
            .ok()
            .filter(|s| !s.trim().is_empty()),
        errors,
        home,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::{Source, State as JobState};
    use serde_json::json;

    /// 2026-11-07T06:45:00-0800.
    const NOW: i64 = 1_794_066_300;
    const SINCE: i64 = NOW - 12 * 3600;

    fn run(name: &str, ok: Option<bool>, result: &str, finished: i64) -> Job {
        let mut j = Job::new(Source::Agentctl, name, JobState::Done);
        j.ok = ok;
        j.result = result.into();
        j.finished = Some(finished);
        j
    }

    fn watch(name: &str, state: &str, since: i64) -> Watch {
        Watch {
            name: name.into(),
            state: state.into(),
            severity: "normal".into(),
            since: Some(since),
            lastrun: None,
            lasttrip: None,
            place: String::new(),
        }
    }

    fn day(date: &str, merged: usize, cost: f64) -> (String, Value) {
        let prs: Vec<Value> = (0..merged)
            .map(|k| json!({"repo": format!("r{}", k % 3)}))
            .collect();
        (
            date.into(),
            json!({"merged": prs, "usage": [{"project": "TOTAL", "sessions": 10, "cost_usd": cost}]}),
        )
    }

    /// Everything green: every runner ok, no trip, no red main, spend at its average.
    fn green() -> Inputs {
        let mut days: Vec<(String, Value)> = (1..=8)
            .rev()
            .map(|d| day(&date_before(NOW, d), 400, 800.0))
            .collect();
        days.last_mut().unwrap().1 = day("", 410, 810.0).1;
        Inputs {
            now: NOW,
            since: SINCE,
            state: json!({
                "generated_epoch": NOW,
                "counts": {"WORKING": 14, "NEEDS": 0, "STALLED": 0},
                "sessions": [], "asks": [], "main": [], "budget": [], "mail": [], "janitor": [],
            }),
            queue: Some(Queue::default()),
            watches: Some(vec![
                watch("board-open", "OK", NOW - 86_400 * 3),
                watch("fleet-liveness", "OK", NOW - 86_400 * 3),
            ]),
            runs: Some(vec![
                run("dream", Some(true), "WORKED", NOW - 3 * 3600),
                run("nightly-sync", Some(true), "WORKED", NOW - 7 * 3600),
                run("shepherd", Some(true), "WORKED", NOW - 4 * 3600),
                run("briefing", Some(false), "FAILED", NOW - 11 * 3600),
            ]),
            calls: Some(vec![]),
            days,
            done: Some(vec![]),
            live: Some(Live {
                lazer_spend: Some(46.0),
                lazer_budget: Some(250.0),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn area<'a>(b: &'a Briefing, name: &str) -> &'a Area {
        b.areas.iter().find(|a| a.name == name).unwrap()
    }

    #[test]
    fn an_all_green_state_renders_every_area_ok_with_no_detail_lines() {
        let b = build(&green());
        assert!(
            b.areas
                .iter()
                .all(|a| a.level == Level::Ok && a.details.is_empty()),
            "{:#?}",
            b.areas
        );
        assert_eq!(b.areas.len(), 6);
        assert_eq!(area(&b, "Workers overnight").line, "3 of 3 ok, $0.00");
        assert_eq!(area(&b, "Nightly").line, "dream, nightly-sync, day-log ok");
        assert_eq!(area(&b, "Infra").line, "2 of 2 watches green");
        assert!(b.needs.is_empty());
        let md = b.markdown();
        assert!(md.contains("- nothing\n"), "{md}");
        assert!(
            md.contains("\n- Costs: ok, $810 yesterday (avg $800, +1%), runners $0.00 since"),
            "{md}"
        );
        // Details holds the runner table and nothing an area raised.
        let details = md.split("## Details").nth(1).unwrap();
        assert_eq!(details.matches("### ").count(), 1, "{md}");
        assert!(details.contains("### Runners since "), "{md}");
        assert!(b.headline.contains(
            "nothing needs you. Yesterday 410 PRs in 3 repos, $810 spent (7-day avg $800)."
        ));
    }

    #[test]
    fn a_failed_runner_and_a_six_day_red_read_workers_bad_and_a_stale_count() {
        let mut i = green();
        i.runs.as_mut().unwrap().push(run(
            "wave-roll",
            Some(false),
            "FAILED",
            NOW - 4 * 3600 - 600,
        ));
        i.watches
            .as_mut()
            .unwrap()
            .push(watch("playground-nightly", "TRIP", NOW - 6 * 86_400));
        let b = build(&i);
        let w = area(&b, "Workers overnight");
        assert_eq!(w.level, Level::Bad);
        assert!(
            w.line.starts_with("3 of 4 ok, $0.00. Failed: wave-roll "),
            "{}",
            w.line
        );
        assert_eq!(w.link, "#fleet?s=failed");
        assert_eq!(w.details.len(), 1);
        let inf = area(&b, "Infra");
        assert_eq!(
            inf.line,
            "2 of 3 watches green; 1 stale red (playground-nightly 6d)"
        );
        // A red from before the window is a count, not a page: the level stays.
        assert_eq!(inf.level, Level::Ok);
        assert!(b.markdown().contains("| wave-roll | 1 | "));

        // Negative control: the same fixture without the failed runner reads ok.
        i.runs.as_mut().unwrap().retain(|j| j.name != "wave-roll");
        assert_eq!(area(&build(&i), "Workers overnight").level, Level::Ok);
    }

    #[test]
    fn since_last_night_shows_what_is_not_ok_and_a_bad_area_carries_its_fix() {
        let n = night(&green());
        assert!(n.rows.is_empty(), "{:#?}", n.rows);
        assert_eq!(n.ok_line, "all 6 areas ok");

        let mut i = green();
        i.runs
            .as_mut()
            .unwrap()
            .push(run("wave-roll", Some(false), "FAILED", NOW - 3600));
        i.runs
            .as_mut()
            .unwrap()
            .push(run("dream", None, "BLOCKED", NOW - 1800));
        i.errors.push("watches: no such dir".into());
        i.home.errors.push("no fleet state yet".into());
        let n = night(&i);
        let names: Vec<&str> = n.rows.iter().map(|r| r.area.name).collect();
        assert_eq!(names, ["Workers overnight", "Nightly"], "briefing order");
        let w = &n.rows[0];
        assert_eq!(w.area.level, Level::Bad);
        let fix = w.fix.as_ref().expect("a bad area queues a fix");
        assert_eq!(fix.project, FIX_PROJECT);
        assert!(
            fix.task
                .starts_with("Fix what the briefing's Workers overnight area reads bad since ")
                && fix.task.contains(&w.area.line)
                && fix.task.contains("#fleet?s=failed"),
            "{}",
            fix.task
        );
        assert_eq!(n.rows[1].area.level, Level::Warn);
        assert!(n.rows[1].fix.is_none(), "only a bad area queues a fix");
        assert_eq!(n.ok_line, "Infra, Sessions, Delivery, Costs ok");
        assert_eq!(n.errors, ["watches: no such dir"], "Home shows its own");
        let v = serde_json::to_value(&n).unwrap();
        assert_eq!(
            v["rows"][0]["name"], "Workers overnight",
            "the area is flat"
        );
        assert_eq!(v["rows"][0]["level"], "bad");
        assert_eq!(v["rows"][0]["fix"]["project"], FIX_PROJECT);
        assert_eq!(fix.queued, None);

        let open = |slug: &str, state, task: &str| queue::Item {
            slug: slug.into(),
            state,
            task: task.into(),
            ..Default::default()
        };
        i.queue.as_mut().unwrap().items = vec![
            open("old", queue::State::Done, &fix.task),
            open(
                "other",
                queue::State::Queued,
                "Fix what the briefing's Nightly area",
            ),
            open(
                "fix-1",
                queue::State::Running,
                &format!("{} earlier line.", fix_head("Workers overnight", i.since)),
            ),
        ];
        let n = night(&i);
        assert_eq!(
            n.rows[0].fix.as_ref().unwrap().queued.as_deref(),
            Some("fix-1"),
            "an open item for this area and window, whatever its line, is the fix already queued"
        );
        i.since -= 86_400;
        let n = night(&i);
        assert_eq!(
            n.rows[0].fix.as_ref().unwrap().queued,
            None,
            "a new window offers it again"
        );
    }

    #[test]
    fn last_night_is_six_in_the_evening_before_today() {
        let t = last_night(NOW);
        let d = Local.timestamp_opt(t, 0).single().unwrap();
        assert_eq!(d.format("%H:%M").to_string(), "18:00");
        assert!(t < NOW && NOW - t <= 30 * 3600 + 3600, "{t}");
    }

    #[test]
    fn a_blocked_run_is_not_ok_in_workers_or_nightly() {
        let mut i = green();
        i.runs
            .as_mut()
            .unwrap()
            .push(run("dream", None, "BLOCKED", NOW - 3600));
        let b = build(&i);
        let w = area(&b, "Workers overnight");
        assert_eq!(w.level, Level::Warn);
        assert_eq!(w.line, "2 of 3 ok, $0.00. Blocked: dream");
        let n = area(&b, "Nightly");
        assert_eq!(n.level, Level::Warn);
        assert_eq!(n.line, "nightly-sync, day-log ok; dream blocked");
        // A budget stop is named once, as the stop.
        i.state["budget"] = serde_json::json!([{"runner": "dream", "detail": "$10.20 of $10"}]);
        let w = area(&build(&i), "Workers overnight").clone();
        assert_eq!(w.line, "2 of 3 ok, $0.00. Budget stop: dream");
    }

    #[test]
    fn a_trip_in_the_window_is_named_and_a_loud_one_is_bad() {
        let mut i = green();
        let mut w = watch("claude-account-pace", "TRIP", NOW - 3600);
        w.severity = "high".into();
        i.watches.as_mut().unwrap().push(w);
        let inf = area(&build(&i), "Infra").clone();
        assert_eq!(inf.level, Level::Bad);
        assert_eq!(inf.details.len(), 1);
        assert!(inf.details[0].starts_with("claude-account-pace tripped at "));
    }

    fn need(kind: Kind, id: &str, text: &str) -> Need {
        Need {
            kind,
            need: home::NeedKind::Ask,
            rank: 0,
            project: "p".into(),
            text: text.into(),
            id: id.into(),
            target: None,
            since: Some(NOW - 9 * 3600),
            recommend: None,
            score: None,
        }
    }

    #[test]
    fn needs_fold_by_kind_in_rank_order_and_leave_reds_to_the_areas() {
        let mut rows: Vec<Need> = (0..9)
            .map(|k| need(Kind::Ask, &format!("ask{k}A"), &format!("Question {k}?")))
            .collect();
        rows[0].recommend = Some("a".into());
        rows[0].target = Some("lab/s:1".into());
        rows.push(need(
            Kind::Budget,
            "budget:dream",
            "dream stopped at its budget: $10.",
        ));
        rows.push(need(Kind::Mail, "mail:a:b", "Critical mail from a: b (x)."));
        rows.push(need(Kind::Nightly, "repo", "repo red"));
        rows.push(need(Kind::Red, "watch x", "watch x"));
        let (n, lines) = needs(&rows, NOW);
        assert_eq!(n, 3);
        assert_eq!(
            lines,
            [
                "9 asks wait on you, 1 holding up a session. Top: Answer ask ask0A: Question 0? (p, 9h, recommend a).",
                "dream stopped at its budget: $10.",
                "Critical mail from a: b (x).",
            ]
        );
    }

    #[test]
    fn past_five_kinds_the_last_slot_points_at_home() {
        let rows = [
            need(Kind::Stopped, "stopped:x", "Dispatch stopped 2h: hold."),
            need(Kind::Ask, "a1", "Q?"),
            need(Kind::Session, "lab/s:1", "Dialog"),
            need(Kind::Queue, "q1", "Do q1"),
            need(Kind::Budget, "budget:dream", "dream stopped."),
            need(Kind::Mail, "mail:a:b", "Critical mail."),
        ];
        let (n, lines) = needs(&rows, NOW);
        assert_eq!(lines.len(), NEEDS_SHOWN);
        assert_eq!(n, 6);
        assert_eq!(
            lines[4],
            "2 more on Home: run hub needs, or open the Home tab."
        );
        assert!(lines.iter().all(|l| l.chars().count() <= ITEM_MAX));
    }

    #[test]
    fn a_source_that_could_not_be_read_says_so_and_never_reads_ok() {
        let mut i = green();
        i.runs = None;
        i.watches = None;
        i.errors.push("watches: no such dir".into());
        let b = build(&i);
        assert_eq!(area(&b, "Workers overnight").level, Level::Warn);
        assert_eq!(area(&b, "Infra").level, Level::Warn);
        assert_eq!(area(&b, "Nightly").level, Level::Warn);
        let md = b.markdown();
        assert!(md.contains("Could not read 1 source"), "{md}");
        assert!(md.contains("- watches: no such dir"), "{md}");
    }

    #[test]
    fn spend_over_the_average_warns_then_goes_bad() {
        let mut i = green();
        i.days.last_mut().unwrap().1 = day("", 410, 1100.0).1;
        assert_eq!(area(&build(&i), "Costs").level, Level::Warn);
        i.days.last_mut().unwrap().1 = day("", 410, 1300.0).1;
        assert_eq!(area(&build(&i), "Costs").level, Level::Bad);
    }

    #[test]
    fn host_issues_drop_their_runbook_hint() {
        let md = "# Health\n## Issues Detected\n- 3 zombie process(es)\n- user units failed: a, b -> do: systemctl --user --failed\n## Next\n- x\n";
        assert_eq!(
            issues(md),
            ["3 zombie process(es)", "user units failed: a, b"]
        );
        assert!(issues("# Health\n").is_empty());
    }
}
