//! The phone widget's rows: `hub phone --json`, published by `agent-mqtt-publish` and laid out by
//! home-config's `phone_widget.jinja`. Plain text and a level, no markup, so the layout lives in
//! one place. Needs come from `home::Home`, so the phone and the hub count the same rows and word
//! the same kind split (`Home::waiting`, `Home::split`); the phone keeps no count of its own.
//!
//! The System block is not here: it is read in the cluster, so it still shows with this machine off.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::home::{Home, Kind, Level};
use crate::infra::Infra;
use crate::projects::{Card, Projects};
use crate::queue::{done_today, DoneToday, Item, Queue};
use crate::text::{age, cap};
use crate::vocab::Vocab;

/// How much of an ask the oldest row keeps: "oldest 13h: " plus this fills one line at 4x4.
const ASK_MAX: usize = 44;
/// One whole widget line at 4x4: the oldest-ask row's "oldest 13h: " plus `ASK_MAX`.
const LINE_MAX: usize = 12 + ASK_MAX;
/// How many projects the needs row names before the rest fold under "+N more".
const PROJECTS: usize = 3;
/// How many projects the Done section lists, busiest first, before the last folds the rest under "+N more": the widget is full
/// at 4x5, so Done is a head and these rows (`widget-preview.sh --check` in home-config says).
const DONE_PROJECTS: usize = 2;
/// How many in-flight projects the projects section lists under its head; the widget is full at
/// 4x4, so the rest fold into the head's count.
const CARDS: usize = 2;
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Row {
    pub level: Level,
    /// The section: red, error, needs, done, agents, queue, ci or projects. A section's first row is its head line,
    /// `Title: value`, and the widget bolds what is before the colon.
    pub head: &'static str,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Phone {
    /// The worst row: ok, warn or critical.
    pub state: &'static str,
    pub rows: Vec<Row>,
    /// When the fleet state these figures were counted from was written (its `generated_epoch`),
    /// None when it could not be read. Every host with `hub` publishes this document, so a reader
    /// takes the newest: a host off the fleet lease counts from a state file that stopped.
    pub as_of: Option<i64>,
    /// Home's Needs you card (`cards::needs`) for a chip that lays out figures, not rows: the
    /// waybar `custom/needs` chip. None when the fleet state could not be read, as the rows.
    pub needs: Option<crate::cards::Card>,
}

/// What `build` reads besides Home, all gathered by the caller.
pub struct Inputs<'a> {
    pub state: &'a Value,
    pub queue: Option<&'a Queue>,
    pub infra: Option<&'a Infra>,
    /// The project cards (`projects::gather`), the ones the waybar chip and the hub draw.
    pub projects: Option<&'a Projects>,
    /// The project of each PR merged today, from the day-log record (`merged_today`).
    pub merged: Option<Vec<String>>,
    pub now: i64,
}

fn row(level: Level, head: &'static str, text: impl Into<String>) -> Row {
    Row {
        level,
        head,
        text: text.into(),
    }
}

/// `n word` for each count above zero, joined: "22 asks, 6 sessions".
fn counted(parts: &[(usize, &str, &str)]) -> String {
    let said: Vec<String> = parts
        .iter()
        .filter(|(n, _, _)| *n > 0)
        .map(|(n, one, many)| format!("{n} {}", if *n == 1 { one } else { many }))
        .collect();
    said.join(", ")
}

/// A repo's name as read aloud: `.dotfiles` is dotfiles.
fn repo(name: &str) -> &str {
    name.trim_start_matches('.')
}

/// The repos whose nightly on main is red: agent work Home routes off Needs you (`Kind::owner`),
/// so the Main red card and the phone's red row name it.
pub fn red_repos(home: &Home) -> Vec<&str> {
    home.routed
        .iter()
        .filter(|n| n.kind == Kind::Nightly)
        .map(|n| repo(&n.project))
        .collect()
}

/// The Needs you rows: Home's one count and its one kind split (`Home::waiting`, `Home::split`),
/// then where the rows sit and the oldest wait.
fn needs(home: &Home, now: i64) -> Vec<Row> {
    let count = home.waiting().count;
    if count == 0 {
        return vec![row(Level::Ok, "needs", "Needs you: nothing")];
    }
    let split: Vec<String> = home
        .split()
        .iter()
        .map(|(label, n)| format!("{label} {n}"))
        .collect();
    let mut out = vec![row(
        Level::Warn,
        "needs",
        format!("Needs you: {count} ({})", split.join(", ")),
    )];

    let mut by: BTreeMap<&str, usize> = BTreeMap::new();
    for n in &home.needs {
        let p = if n.project.is_empty() {
            "other"
        } else {
            repo(&n.project)
        };
        *by.entry(p).or_default() += 1;
    }
    let mut by: Vec<(&str, usize)> = by.into_iter().collect();
    by.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    let mut named: Vec<String> = by
        .iter()
        .take(PROJECTS)
        .map(|(p, n)| format!("{p} {n}"))
        .collect();
    if by.len() > PROJECTS {
        named.push(format!("+{} more", by.len() - PROJECTS));
    }
    out.push(row(Level::Ok, "needs", named.join(", ")));

    if let Some((since, n)) = home
        .needs
        .iter()
        .filter_map(|n| n.since.map(|s| (s, n)))
        .min_by_key(|(s, _)| *s)
    {
        let line = format!("oldest {}: {}", age(now - since), cap(&n.text, ASK_MAX));
        out.push(row(Level::Ok, "needs", line));
    }
    out
}

/// "14 overdue (longest phase open 21h), next done 10:12", from the sessions still live: overdue
/// is fleet-sessions' verdict on each (`overdue`, the shepherd's rule), never a past ETA.
fn etas(state: &Value, now: i64) -> Option<String> {
    let vocab = Vocab::from_state(state);
    let live: Vec<&Value> = state["sessions"]
        .as_array()?
        .iter()
        .filter(|s| vocab.in_progress(s["bucket"].as_str().unwrap_or("")))
        .collect();
    let late: Vec<i64> = live
        .iter()
        .filter_map(|s| s["overdue"]["age_min"].as_i64())
        .collect();
    let mut said = vec![];
    if let Some(longest) = late.iter().max() {
        said.push(format!(
            "{} overdue (longest phase open {})",
            late.len(),
            age(longest * 60)
        ));
    }
    if let Some(next) = live
        .iter()
        .filter_map(|s| s["eta_epoch"].as_i64())
        .filter(|e| *e >= now)
        .min()
    {
        let at = chrono::DateTime::from_timestamp(next, 0)?.with_timezone(&chrono::Local);
        said.push(format!("next done {}", at.format("%H:%M")));
    }
    (!said.is_empty()).then(|| said.join(", "))
}

/// The value of `name` for `kpi` (and `window`, when it has one) in the bench series.
pub(crate) fn kpi(infra: &Infra, name: &str, kpi: &str, window: &str) -> Option<f64> {
    infra
        .get("bench")
        .iter()
        .find(|s| {
            s.label("__name__") == name && s.label("kpi") == kpi && s.label("window") == window
        })
        .and_then(|s| s.value)
}

fn agents(i: &Inputs) -> Vec<Row> {
    let Some(c) = i.state["counts"].as_object() else {
        return vec![];
    };
    let n = |k: &str| c.get(k).and_then(Value::as_u64).unwrap_or(0) as usize;
    let mut head = format!("Agents: {} working", n("WORKING"));
    // CHAT (the human's own conversation) and PARKED are not attention, so the phone leaves them out.
    let rest = counted(&[(n("STALLED"), "stalled", "stalled")]);
    if !rest.is_empty() {
        head += &format!(", {rest}");
    }
    let level = if n("STALLED") > 0 {
        Level::Warn
    } else {
        Level::Ok
    };
    let mut out = vec![row(level, "agents", head)];

    let infra = i.infra.filter(|x| x.ok);
    if let Some(line) = etas(i.state, i.now) {
        out.push(row(Level::Ok, "agents", line));
    }
    // One line; the rows are on Home (dashboards rule 2). fleet-bench judges, vitals words it. With
    // no gauges there is nothing to flag here: Home says it has no reading.
    let vitals = infra.and_then(crate::vitals::read);
    if let Some(v) = vitals.filter(|v| !v.all_ok && !v.rows.is_empty()) {
        out.push(row(Level::Warn, "agents", format!("Vitals: {}", v.line)));
    }
    out
}

/// "Done today: 40 shipped, 12 checks, 33 PRs merged", then one line per project, busiest first:
/// "unity-core-playground 30 shipped, 2 checks, 25 PRs", the last ending ", +3 more" when there are
/// others. Shipped and checks are `Queue::done_today`, the figure the Projects card and the waybar
/// chip show; each project's line groups the same items by `queue::done_today`; PRs come from the
/// day-log, so each source counts only when it could be read; with neither there is no section.
fn done(i: &Inputs) -> Vec<Row> {
    let midnight = crate::text::local_day_start(i.now);
    // A failed `agent-queue list` leaves no items, which is not the same as none done today.
    let items: Option<BTreeMap<&str, DoneToday>> = i.queue.filter(|q| q.list_read()).map(|q| {
        let mut by: BTreeMap<&str, Vec<&Item>> = BTreeMap::new();
        for x in &q.items {
            let p = if x.project.is_empty() {
                "other"
            } else {
                repo(&x.project)
            };
            by.entry(p).or_default().push(x);
        }
        by.into_iter()
            .map(|(p, v)| (p, done_today(v, midnight)))
            .filter(|(_, d)| d.shipped + d.checks > 0)
            .collect()
    });
    let prs = i.merged.as_ref();
    if items.is_none() && prs.is_none() {
        return vec![];
    }
    let plural =
        |n: usize, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
    let mut head = vec![];
    // The head is the Projects card's figure (`Queue::done_today`), not a sum of the rows below.
    if let Some(d) = i.queue.and_then(|q| q.done_today(i.now)) {
        head.push(format!("{} shipped", d.shipped));
        head.push(plural(d.checks, "check", "checks"));
    }
    if let Some(v) = prs {
        head.push(plural(v.len(), "PR merged", "PRs merged"));
    }
    let mut out = vec![row(
        Level::Ok,
        "done",
        format!("Done today: {}", head.join(", ")),
    )];

    let mut by: BTreeMap<&str, (DoneToday, usize)> = BTreeMap::new();
    for (p, d) in items.iter().flatten() {
        by.entry(p).or_default().0 = *d;
    }
    for p in prs.into_iter().flatten() {
        by.entry(repo(p)).or_default().1 += 1;
    }
    let mut by: Vec<(&str, (DoneToday, usize))> = by.into_iter().collect();
    by.sort_by_key(|(name, (d, m))| (std::cmp::Reverse(d.shipped + d.checks + m), *name));
    let shown = by.len().min(DONE_PROJECTS);
    for (k, (name, (d, m))) in by.iter().take(shown).enumerate() {
        // The fold rides on the last row, so the section stays a head and `DONE_PROJECTS` lines.
        let fold = if k + 1 == shown && by.len() > shown {
            format!(", +{} more", by.len() - shown)
        } else {
            String::new()
        };
        let tail = format!(
            " {}{fold}",
            counted(&[
                (d.shipped, "shipped", "shipped"),
                (d.checks, "check", "checks"),
                (*m, "PR", "PRs")
            ])
        );
        let room = LINE_MAX.saturating_sub(tail.chars().count());
        out.push(row(Level::Ok, "done", format!("{}{tail}", cap(name, room))));
    }
    out
}

/// "Queue: 14 running, 16 on deck", then one detail line: the oldest queued item's wait and
/// what a PR costs, "oldest waited 37h, $4.24 per PR (28d $5.90)". What the queue delivered
/// today is the Done section's. The cost stands without the queue.
fn queue(i: &Inputs) -> Vec<Row> {
    let mut out = vec![];
    let mut said = vec![];
    if let Some(q) = i.queue {
        out.push(row(
            Level::Ok,
            "queue",
            format!("Queue: {}", q.counts_line()),
        ));
        let sitting = q.stats.as_ref().and_then(|s| s.sitting.as_ref());
        if let Some(o) = sitting.and_then(|s| s.oldest_runnable.first()) {
            said.push(format!("oldest waited {}", age(o.minutes * 60)));
        }
    }
    if let Some(inf) = i.infra.filter(|x| x.ok) {
        if let Some(w) = kpi(inf, "agent_bench_kpi", "cost_per_pr", "7d") {
            let month = kpi(inf, "agent_bench_kpi", "cost_per_pr", "28d")
                .map_or(String::new(), |m| format!(" (28d ${m:.2})"));
            said.push(format!("${w:.2} per PR{month}"));
        }
    }
    if !said.is_empty() {
        out.push(row(Level::Ok, "queue", said.join(", ")));
    }
    out
}

/// One card as the widget says it: "agent-runtime at risk, 21/84 due 11-22, 4 running", its
/// state first (`projects::state`), the window after it unless it repeats `no window`. Past
/// `LINE_MAX` the counts shorten to "11 run, 1 wait", and then only the name is capped, so the
/// state, window and counts always show.
fn project(c: &Card) -> String {
    let lead = crate::projects::state_says(c);
    let rest = |run: &str, wait: &str| {
        let mut s = format!(" {lead}");
        if !c.running.is_empty() {
            s += &format!(", {} {run}", c.running.len());
        }
        if c.waiting > 0 {
            s += &format!(", {} {wait}", c.waiting);
        }
        s
    };
    let mut tail = rest("running", "waiting");
    if c.name.chars().count() + tail.chars().count() > LINE_MAX {
        tail = rest("run", "wait");
    }
    let room = LINE_MAX.saturating_sub(tail.chars().count());
    format!("{}{tail}", cap(&c.name, room))
}

/// "Projects: 4 in flight of 25", then the first `CARDS` in flight, one line each, in the
/// cards' own order (in flight first); the head's count says how many more there are. Nothing in
/// flight is the head line alone, since a green section is one line.
fn projects(p: &Projects) -> Vec<Row> {
    let flying: Vec<&Card> = p.cards.iter().filter(|c| c.in_flight()).collect();
    if p.cards.is_empty() {
        return vec![];
    }
    let mut out = vec![row(
        Level::Ok,
        "projects",
        if flying.is_empty() {
            format!("Projects: nothing in flight of {}", p.cards.len())
        } else {
            format!("Projects: {} in flight of {}", flying.len(), p.cards.len())
        },
    )];
    out.extend(flying.iter().take(CARDS).map(|c| {
        let hue = crate::projects::state_level(c.state).map_or(Level::Ok, Level::from);
        row(hue, "projects", project(c))
    }));
    out
}

/// "CI: 6.0/20 busy, 79% passed, aws-burst-1 offline": the glance the bar and the Infra tab read
/// (slot units), naming only what is down; no row while the governor publishes no units.
fn ci(infra: &Infra) -> Option<Row> {
    let g = &infra.ci.glance;
    g.units?;
    let mut said = vec![format!("CI: {} busy", g.units_line())];
    if g.queued > 0 {
        said.push(format!("{} queued", g.queued));
    }
    if let Some(p) = g.pass {
        said.push(format!("{:.0}% passed", p * 100.0));
    }
    let mut down: Vec<&str> = infra
        .runners_down()
        .into_iter()
        .map(|s| s.label("host"))
        .filter(|h| !h.is_empty())
        .collect();
    down.sort();
    down.dedup();
    let level = if down.is_empty() {
        Level::Ok
    } else {
        Level::Warn
    };
    if !down.is_empty() {
        said.push(format!("{} offline", down.join(", ")));
    }
    Some(row(level, "ci", said.join(", ")))
}

/// The rows, most urgent first. A section with nothing to say is one line or none, and what could
/// not be read is a row of its own, so a short view never reads as an all-clear.
pub fn build(home: &Home, i: &Inputs) -> Phone {
    let mut rows = vec![];
    let nightly = red_repos(home);
    if !nightly.is_empty() {
        rows.push(row(
            Level::Red,
            "red",
            format!("main red: {}", nightly.join(", ")),
        ));
    }
    rows.extend(
        home.errors
            .iter()
            .map(|e| row(Level::Warn, "error", cap(e, ASK_MAX))),
    );
    if !i.state.is_null() {
        rows.extend(needs(home, i.now));
    }
    rows.extend(done(i));
    rows.extend(agents(i));
    rows.extend(queue(i));
    rows.extend(i.infra.filter(|x| x.ok).and_then(ci));
    rows.extend(i.projects.map(projects).unwrap_or_default());
    let worst = |l: Level| rows.iter().any(|r| r.level == l);
    let state = if worst(Level::Red) {
        "critical"
    } else if worst(Level::Warn) {
        "warn"
    } else {
        "ok"
    };
    Phone {
        state,
        rows,
        as_of: i.state["generated_epoch"].as_i64(),
        needs: (!i.state.is_null()).then(|| crate::cards::needs(home, i.now)),
    }
}

/// The project of each PR merged today, from the day-log record (`DAYLOG_DIR`); None when there
/// is no record yet.
pub fn merged_today() -> Option<Vec<String>> {
    let dir = std::env::var("DAYLOG_DIR").unwrap_or_else(|_| {
        format!(
            "{}/.agent/daylog",
            std::env::var("HOME").unwrap_or_default()
        )
    });
    let day = chrono::Local::now().format("%F");
    let text = std::fs::read_to_string(format!("{dir}/{day}.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let merged = v["merged"].as_array()?;
    Some(merged.iter().map(crate::boards::pr_project).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::home;
    use crate::prom;
    use crate::queue::{Item, State};
    use serde_json::json;

    const NOW: i64 = 1_800_000_000;

    fn series(rows: Vec<Value>) -> Vec<prom::Series> {
        let resp = json!({"status": "success", "data": {"result": rows}});
        prom::flatten(&resp).unwrap()
    }

    fn metric(name: &str, labels: Value, v: &str) -> Value {
        let mut m = labels;
        m["__name__"] = json!(name);
        json!({"metric": m, "value": [0, v]})
    }

    fn infra(extra: Vec<(&'static str, Vec<Value>)>) -> Infra {
        let mut inf = Infra::default();
        inf.instant.insert(
            "cc",
            series(vec![metric("cc:overall_status", json!({}), "0")]),
        );
        for (k, rows) in extra {
            inf.instant.insert(k, series(rows));
        }
        crate::infra::judge(&mut inf, vec![]);
        // The line reads the glance, each slot once.
        inf.ci.glance = crate::ci::Glance {
            busy: 6,
            slots: 20,
            units_busy: Some(6.0),
            units: Some(20.0),
            pass: Some(0.8),
            ..Default::default()
        };
        inf
    }

    fn bench() -> Vec<Value> {
        vec![
            metric(
                "agent_bench_waiting_hours",
                json!({"project": "a"}),
                "150.4",
            ),
            metric("agent_bench_waiting_hours", json!({"project": "b"}), "42.6"),
            metric(
                "agent_bench_kpi",
                json!({"kpi": "ci_red_per_pr", "window": "7d"}),
                "0.863",
            ),
            metric(
                "agent_bench_kpi_limit",
                json!({"kpi": "ci_red_per_pr"}),
                "0.5",
            ),
            metric("agent_bench_kpi_past", json!({"kpi": "ci_red_per_pr"}), "1"),
            metric(
                "agent_bench_vital",
                json!({"question": "output", "kpi": "revert_rate"}),
                "0",
            ),
            metric(
                "agent_bench_vital",
                json!({"question": "flow", "kpi": "board_open"}),
                "1",
            ),
            metric(
                "agent_bench_kpi",
                json!({"kpi": "board_open", "window": "7d"}),
                "372",
            ),
            metric("agent_bench_kpi_limit", json!({"kpi": "board_open"}), "60"),
            metric("agent_bench_kpi_past", json!({"kpi": "board_open"}), "1"),
            metric(
                "agent_bench_kpi",
                json!({"kpi": "revert_rate", "window": "7d"}),
                "0.002",
            ),
            metric(
                "agent_bench_kpi_limit",
                json!({"kpi": "revert_rate"}),
                "0.05",
            ),
            metric("agent_bench_kpi_past", json!({"kpi": "revert_rate"}), "0"),
            metric(
                "agent_bench_kpi",
                json!({"kpi": "cost_per_pr", "window": "7d"}),
                "6.538",
            ),
            metric(
                "agent_bench_kpi",
                json!({"kpi": "cost_per_pr", "window": "28d"}),
                "7.004",
            ),
        ]
    }

    fn state() -> Value {
        json!({
            "generated_epoch": NOW,
            "counts": {"WORKING": 8, "STALLED": 1, "CHAT": 3, "NEEDS": 2},
            "asks": [
                {"id": "aB1", "project": "unity-core-playground", "question": "Which title?",
                 "created": 1799949600, "session": "s1"},
                {"id": "aB2", "project": ".dotfiles", "question": "Keep it?", "session": ""},
            ],
            "main": [{"repo": ".dotfiles", "reason": "red"}],
            "vocab": {"buckets": ["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"],
                      "in_progress": ["WORKING", "NEEDS", "STALLED"]},
            "sessions": [
                {"target": "w/s2:1", "bucket": "WORKING", "cwd": "/x/trader", "eta_epoch": NOW - 7200,
                 "overdue": {"phase": "phase 2/4", "age_min": 125}},
                {"target": "w/s3:1", "bucket": "NEEDS", "cwd": "/x/trader", "idle_min": 30,
                 "reason": "permission", "eta_epoch": NOW - 3600},
                {"target": "w/s4:1", "bucket": "WORKING", "cwd": "/x/y", "eta_epoch": NOW + 600},
                {"target": "w/s5:1", "bucket": "DONE", "cwd": "/x/y", "eta_epoch": NOW - 90000,
                 "overdue": {"phase": "phase 1/1", "age_min": 9000}},
            ],
        })
    }

    fn queue_of(items: Vec<(State, &str)>) -> Queue {
        let items = items
            .into_iter()
            .map(|(state, slug)| Item {
                slug: slug.into(),
                project: "p".into(),
                state,
                ..Item::default()
            })
            .collect();
        Queue {
            items,
            ..Queue::default()
        }
    }

    /// `n` merged PRs, two of every three in one project.
    fn merged(n: usize) -> Vec<String> {
        (0..n)
            .map(|k| {
                if k % 3 == 2 {
                    "dotfiles"
                } else {
                    "unity-core-playground"
                }
                .to_string()
            })
            .collect()
    }

    fn done_item(slug: &str, project: &str, finished: i64) -> Item {
        Item {
            slug: slug.into(),
            project: project.into(),
            state: State::Done,
            status: Some("ok".into()),
            finished: Some(
                chrono::DateTime::from_timestamp(finished, 0)
                    .unwrap()
                    .to_rfc3339(),
            ),
            ..Item::default()
        }
    }

    fn phone(state: &Value, q: Option<&Queue>, inf: Option<&Infra>) -> Phone {
        let h = home::build(Some(state), q, None, inf, NOW);
        build(
            &h,
            &Inputs {
                state,
                queue: q,
                infra: inf,
                projects: None,
                merged: Some(merged(85)),
                now: NOW,
            },
        )
    }

    fn texts(p: &Phone, head: &str) -> Vec<String> {
        p.rows
            .iter()
            .filter(|r| r.head == head)
            .map(|r| r.text.clone())
            .collect()
    }

    #[test]
    fn needs_count_the_rows_home_counts() {
        let (s, q) = (state(), queue_of(vec![(State::Waiting, "w1")]));
        let inf = infra(vec![]);
        let p = phone(&s, Some(&q), Some(&inf));
        let home = home::build(Some(&s), Some(&q), None, Some(&inf), NOW);
        let needs = texts(&p, "needs");
        assert_eq!(home.waiting().count, 4);
        assert_eq!(
            needs[0],
            "Needs you: 4 (Question 2, Your turn 1, Blocked 1)"
        );
        assert!(needs[1].starts_with("dotfiles 1"), "{}", needs[1]);
    }

    /// Where the cards, the widget document, the published `figures` and the phone's heads say
    /// different numbers for one card figure, one line each; empty when every surface agrees.
    fn disagree(
        cards: &[crate::cards::Card],
        doc: &crate::widget_doc::Document,
        figs: &BTreeMap<String, i64>,
        p: &Phone,
    ) -> Vec<String> {
        use crate::widget_doc::Item as W;
        let mut bad = vec![];
        let mut want = BTreeMap::new();
        for c in cards {
            let Some(sec) = doc.sections.iter().find(|x| x.id == c.tab) else {
                bad.push(format!("{}: no section in the document", c.tab));
                continue;
            };
            let metric = sec.items.iter().find_map(|i| match i {
                W::Metric { value, .. } => Some(value.as_str()),
                _ => None,
            });
            // An empty big (Costs with nothing read) is no metric at all.
            if metric != Some(c.big.as_str()).filter(|b| !b.is_empty()) {
                bad.push(format!("{}: card {} but document {metric:?}", c.tab, c.big));
            }
            let pills: Vec<(&str, &str)> = sec
                .items
                .iter()
                .filter_map(|i| match i {
                    W::Pill { label, value, .. } => Some((label.as_str(), value.as_str())),
                    _ => None,
                })
                .collect();
            let parts: Vec<(&str, &str)> = c
                .parts
                .iter()
                .map(|x| (x.label.as_str(), x.value.as_str()))
                .collect();
            if pills != parts {
                bad.push(format!(
                    "{}: card parts {parts:?} but document {pills:?}",
                    c.tab
                ));
            }
            if let Ok(n) = c.big.parse::<i64>() {
                want.insert(format!("{}_headline", c.tab), n);
            }
            for (l, v) in parts {
                if let Ok(n) = v.parse::<i64>() {
                    want.insert(crate::widget_doc::figure_name(c.tab, l), n);
                }
            }
        }
        if *figs != want {
            bad.push(format!("figures {figs:?} but the cards say {want:?}"));
        }
        let card = |tab: &str| cards.iter().find(|c| c.tab == tab);
        let part = |tab: &str, label: &str| {
            card(tab)
                .and_then(|c| c.parts.iter().find(|x| x.label == label))
                .map_or("?", |x| x.value.as_str())
        };
        let head = |h: &str| texts(p, h).first().cloned().unwrap_or_default();
        let mut says = |what: &str, got: String, want: String| {
            if !got.starts_with(&want) {
                bad.push(format!("phone {what}: {got:?}, the cards say {want:?}"));
            }
        };
        if let Some(n) = card("needs") {
            let split: Vec<String> = n
                .parts
                .iter()
                .map(|x| format!("{} {}", x.label, x.value))
                .collect();
            says(
                "needs",
                head("needs"),
                format!("Needs you: {} ({})", n.big, split.join(", ")),
            );
        }
        says(
            "queue",
            head("queue"),
            format!(
                "Queue: {} running, {} on deck",
                part("queue", "Running"),
                part("queue", "On deck")
            ),
        );
        let checks = part("projects", "Checks closed");
        says(
            "done",
            head("done"),
            format!(
                "Done today: {} shipped, {checks} {}",
                part("projects", "Shipped today"),
                if checks == "1" { "check" } else { "checks" }
            ),
        );
        if let Some(c) = card("projects") {
            says(
                "projects",
                head("projects"),
                format!(
                    "Projects: {} in flight of {}",
                    part("projects", "In flight"),
                    c.big
                ),
            );
        }
        // Not checked: the phone's Agents head counts fleet-sessions' `counts` while the Sessions
        // card counts the live rows; one source for both is the outbox item "sessions figures
        // from one source" (plan ar-4329).
        bad
    }

    /// Every card figure from one fixture, on every surface that shows it: the card (the hub and
    /// agent-web draw it as is), the widget document (`/widget.json`, Tilecast), `figures` (the
    /// publisher's summary/cards, so the waybar chips and Home Assistant) and the phone's heads
    /// (`hub phone --json`). The publisher sends the document unchanged (agent_mqtt_publish.bats).
    #[test]
    fn every_card_figure_reads_the_same_on_every_surface() {
        let s = state();
        let mut q = queue_of(vec![
            (State::Waiting, "w1"),
            (State::Running, "r1"),
            (State::Queued, "q1"),
            (State::Queued, "q2"),
        ]);
        q.stats = Some(crate::queue::Stats {
            sitting: Some(crate::queue::Sitting {
                queued: 2,
                runnable: 1,
                ..Default::default()
            }),
            ..Default::default()
        });
        q.items[1].project = "agent-runtime".into();
        let mut shipped = done_item("a", "agent-runtime", NOW);
        shipped.merged = Some("abc123".into());
        q.items.push(shipped);
        q.items.push(done_item("b", "agent-runtime", NOW));
        // An item whose project is no lab project still counts: one figure for the whole queue.
        let mut stray = done_item("c", "scratch", NOW);
        stray.merged = Some("def456".into());
        q.items.push(stray);
        let inf = infra(vec![]);
        let stats: Vec<crate::projects::Stats> = ["agent-runtime", "unity-core-playground"]
            .iter()
            .map(|n| crate::projects::Stats {
                name: n.to_string(),
                ..Default::default()
            })
            .collect();
        let at = chrono::DateTime::from_timestamp(NOW, 0).unwrap();
        let projects = crate::projects::build(&stats, None, &s, Some(&q), at);
        let home = home::build(Some(&s), Some(&q), None, Some(&inf), NOW);
        let vocab = Vocab::from_state(&s);
        let sessions = crate::session_table::rows(
            s["sessions"].as_array().unwrap(),
            &vocab,
            &Default::default(),
            &[],
        );
        let board = crate::tasks::Feed::default();
        let alerts = crate::alerts::Alerts::default();
        let costs = crate::costs::Costs::default();
        let releases = crate::releases::Releases::default();
        let schedules = crate::schedules::Schedules::default();
        let mut cards = vec![
            crate::cards::needs(&home, NOW),
            crate::cards::main_red(&home),
        ];
        cards.extend(crate::cards::grid(&crate::cards::Reads {
            sessions: Some(Ok(&sessions)),
            board: Some(Ok(&board)),
            queue: Some(Ok(&q)),
            pipeline: None,
            alerts: Some(Ok(&alerts)),
            infra: Some(Ok(&inf)),
            costs: Some(Ok(&costs)),
            releases: Some(Ok(&releases)),
            schedules: Some(Ok(&schedules)),
            projects: Some(Ok(&projects)),
        }));
        assert_eq!(
            cards.iter().map(|c| c.tab).collect::<Vec<_>>(),
            crate::cards::ORDER,
            "every card is in the check"
        );
        let doc = crate::widget_doc::document(&cards, &[], NOW, None);
        let figs = crate::widget_doc::figures(&cards);
        let p = build(
            &home,
            &Inputs {
                state: &s,
                queue: Some(&q),
                infra: Some(&inf),
                projects: Some(&projects),
                merged: None,
                now: NOW,
            },
        );
        assert_eq!(disagree(&cards, &doc, &figs, &p), Vec::<String>::new());
        // The fixture reaches the figures the phone shares: shipped counts the stray project's
        // item, and on deck is the runnable count, not every queued item.
        assert_eq!(figs["projects_shipped_today"], 2);
        assert_eq!(figs["projects_checks_closed"], 1);
        assert_eq!(figs["queue_on_deck"], 1);
        assert!(figs["needs_headline"] > 0);

        // Negative controls: a surface that counts a figure itself fails the check.
        let mut d = doc.clone();
        let queue = d.sections.iter_mut().find(|x| x.id == "queue").unwrap();
        for i in &mut queue.items {
            if let crate::widget_doc::Item::Pill { label, value, .. } = i {
                if label == "On deck" {
                    *value = "2".into();
                }
            }
        }
        assert_eq!(
            disagree(&cards, &d, &figs, &p).len(),
            1,
            "a document that recounts on deck"
        );
        let mut f = figs.clone();
        f.insert("projects_shipped_today".into(), 3);
        assert_eq!(
            disagree(&cards, &doc, &f, &p).len(),
            1,
            "a figure that recounts shipped"
        );
        let mut ph = p.clone();
        let done = ph.rows.iter_mut().find(|r| r.head == "done").unwrap();
        // The old Projects card's count: shipped over the lab projects only.
        done.text = "Done today: 1 shipped, 1 check".into();
        assert_eq!(
            disagree(&cards, &doc, &figs, &ph).len(),
            1,
            "a phone that recounts shipped"
        );
        // A Home row of any kind moves the needs figure on every surface together.
        let mut more = home.clone();
        more.needs.push(more.needs[0].clone());
        more.needs.last_mut().unwrap().kind = Kind::Sheet;
        assert_eq!(
            crate::cards::needs(&more, NOW).big,
            (home.waiting().count + 1).to_string()
        );
    }

    #[test]
    fn the_needs_card_rides_the_document_with_the_state_age() {
        let (s, q) = (state(), queue_of(vec![(State::Waiting, "w1")]));
        let inf = infra(vec![]);
        let home = home::build(Some(&s), Some(&q), None, Some(&inf), NOW);
        let p = phone(&s, Some(&q), Some(&inf));
        let card = p.needs.expect("a read state carries the needs card");
        assert_eq!(card.big, home.waiting().count.to_string());
        assert_eq!(p.as_of, Some(NOW));
        // Negative control: no state read is no card and no age, never a zero.
        let none = phone(&Value::Null, Some(&q), Some(&inf));
        assert_eq!(none.needs, None);
        assert_eq!(none.as_of, None);
    }

    #[test]
    fn the_heuristics_are_counted_and_keep_their_baselines() {
        let s = state();
        let inf = infra(vec![("bench", bench())]);
        let agents = texts(&phone(&s, None, Some(&inf)), "agents");
        let next = chrono::DateTime::from_timestamp(NOW + 600, 0)
            .unwrap()
            .with_timezone(&chrono::Local)
            .format("%H:%M");
        assert_eq!(
            agents,
            [
                "Agents: 8 working, 1 stalled".to_string(),
                format!("1 overdue (longest phase open 2h), next done {next}"),
                "Vitals: 1 of 2 off target: Flow".to_string(),
            ]
        );
        // What a PR costs reads with the queue; how many merged is the Done section's.
        assert_eq!(
            texts(&phone(&s, None, Some(&inf)), "queue"),
            ["$6.54 per PR (28d $7.00)"]
        );
    }

    #[test]
    fn the_queue_says_on_deck_and_how_long_the_oldest_waited() {
        let mut q = queue_of(vec![
            (State::Running, "r1"),
            (State::Queued, "q1"),
            (State::Queued, "q2"),
        ]);
        q.stats = Some(crate::queue::Stats {
            sitting: Some(crate::queue::Sitting {
                // Two queued, one of them held: the line counts what is on deck.
                queued: 2,
                runnable: 1,
                oldest_runnable: vec![crate::queue::Waiter {
                    minutes: 37 * 60,
                    ..Default::default()
                }],
                ..Default::default()
            }),
            ..Default::default()
        });
        let p = phone(&state(), Some(&q), Some(&infra(vec![("bench", bench())])));
        assert_eq!(
            texts(&p, "queue"),
            [
                "Queue: 1 running, 1 on deck",
                "oldest waited 37h, $6.54 per PR (28d $7.00)",
            ]
        );
    }

    #[test]
    fn done_leads_with_the_day_per_project_and_counts_only_what_was_read() {
        let mut q = queue_of(vec![(State::Running, "r1")]);
        // Every finish is NOW itself, so the machine's timezone cannot move one across midnight.
        // a and c merged (shipped); b merged nothing (a check), and so did a's second run.
        let merged = |mut x: Item| {
            x.merged = Some("abc123".into());
            x
        };
        q.items.push(merged(done_item("a", "agent-runtime", NOW)));
        q.items.push(done_item("a", "agent-runtime", NOW));
        q.items.push(done_item("b", "agent-runtime", NOW));
        q.items.push(merged(done_item("c", ".dotfiles", NOW)));
        q.items
            .push(done_item("old", "agent-runtime", NOW - 3 * 86400));
        // Negative control: a failed run with a merge counts in neither.
        let mut failed = merged(done_item("bad", "agent-runtime", NOW));
        failed.status = Some("failed".into());
        q.items.push(failed);
        let p = phone(&state(), Some(&q), Some(&infra(vec![])));
        assert_eq!(
            texts(&p, "done"),
            [
                "Done today: 2 shipped, 1 check, 85 PRs merged",
                "unity-core-playground 57 PRs",
                "dotfiles 1 shipped, 28 PRs, +1 more",
            ]
        );
        // After Needs, before Agents: near the top, not a detail under Queue.
        let heads: Vec<&str> = p.rows.iter().map(|r| r.head).collect();
        let at = |h: &str| heads.iter().position(|x| *x == h).unwrap();
        assert!(at("needs") < at("done") && at("done") < at("agents"));
        assert!(at("done") < at("queue"));
    }

    #[test]
    fn done_names_the_busiest_projects_and_folds_the_rest() {
        let mut q = queue_of(vec![]);
        for (k, name) in ["a", "b", "c", "d", "e"].iter().enumerate() {
            for n in 0..=k {
                q.items.push(done_item(&format!("{name}{n}"), name, NOW));
            }
        }
        let h = home::build(Some(&state()), Some(&q), None, None, NOW);
        let p = build(
            &h,
            &Inputs {
                state: &state(),
                queue: Some(&q),
                infra: None,
                projects: None,
                merged: None,
                now: NOW,
            },
        );
        assert_eq!(
            texts(&p, "done"),
            [
                "Done today: 0 shipped, 15 checks",
                "e 5 checks",
                "d 4 checks, +3 more",
            ]
        );
    }

    #[test]
    fn a_failed_queue_list_is_not_a_zero_and_a_missing_status_counts_in_neither() {
        // agent-queue stats counts only status ok, so the phone does too (no done item in the
        // ledger lacked a status, 2026-11-21).
        let mut q = queue_of(vec![]);
        let mut bare = done_item("a", "p", NOW);
        bare.status = None;
        q.items.push(bare);
        let p = phone(&state(), Some(&q), None);
        assert_eq!(
            texts(&p, "done")[0],
            "Done today: 0 shipped, 0 checks, 85 PRs merged"
        );
        q.items.clear();
        q.errors.push("agent-queue list: boom".into());
        let p = phone(&state(), Some(&q), None);
        assert_eq!(texts(&p, "done")[0], "Done today: 85 PRs merged");
    }

    #[test]
    fn done_is_absent_when_neither_source_could_be_read() {
        let h = home::build(Some(&state()), None, None, None, NOW);
        let p = build(
            &h,
            &Inputs {
                state: &state(),
                queue: None,
                infra: None,
                projects: None,
                merged: None,
                now: NOW,
            },
        );
        assert!(texts(&p, "done").is_empty());
    }

    #[test]
    fn ci_sums_the_sites_and_names_only_what_is_down() {
        let runners = vec![
            metric("x", json!({"host": "aws-burst-1", "state": "offline"}), "0"),
            metric("x", json!({"host": "aws-burst-1", "state": "offline"}), "0"),
            metric("x", json!({"host": "box", "state": "idle"}), "1"),
        ];
        let inf = infra(vec![("runners", runners.clone())]);
        let p = phone(&state(), None, Some(&inf));
        assert_eq!(
            texts(&p, "ci"),
            ["CI: 6.0/20 busy, 80% passed, aws-burst-1 offline"]
        );
        // Powered off by the governor, its runners are offline by design: nothing is down.
        let stopped = metric(
            "ci_governor_power_state",
            json!({"host": "aws-burst-1", "state": "stopped"}),
            "1",
        );
        let inf = infra(vec![("runners", runners), ("power", vec![stopped])]);
        let p = phone(&state(), None, Some(&inf));
        assert_eq!(texts(&p, "ci"), ["CI: 6.0/20 busy, 80% passed"]);
    }

    #[test]
    fn an_all_green_fleet_is_one_line_a_section() {
        let s = json!({"generated_epoch": NOW, "counts": {"WORKING": 2}, "asks": [], "main": [], "sessions": []});
        let q = queue_of(vec![(State::Running, "r1")]);
        let inf = infra(vec![]);
        let p = phone(&s, Some(&q), Some(&inf));
        assert_eq!(p.state, "ok");
        assert_eq!(
            p.rows.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            [
                "Needs you: nothing",
                "Done today: 0 shipped, 0 checks, 85 PRs merged",
                "unity-core-playground 57 PRs",
                "dotfiles 28 PRs",
                "Agents: 2 working",
                "Queue: 1 running, 0 queued",
                "CI: 6.0/20 busy, 80% passed",
            ]
        );
    }

    #[test]
    fn a_red_main_is_critical_and_leads() {
        let p = phone(&state(), None, Some(&infra(vec![])));
        assert_eq!(p.state, "critical");
        assert_eq!(p.rows[0].head, "red");
        assert_eq!(p.rows[0].text, "main red: dotfiles");
    }

    #[test]
    fn no_prometheus_says_so_and_keeps_what_it_can_read() {
        let inf = Infra {
            error: Some("cannot read https://p".into()),
            ..Infra::default()
        };
        let p = phone(&state(), None, Some(&inf));
        assert_eq!(texts(&p, "error"), ["Prometheus: cannot read https://p"]);
        assert!(texts(&p, "ci").is_empty());
        let agents = texts(&p, "agents");
        assert_eq!(agents[0], "Agents: 8 working, 1 stalled");
        assert!(texts(&p, "queue").is_empty());
        assert_eq!(texts(&p, "done")[0], "Done today: 85 PRs merged");
    }

    #[test]
    fn no_state_file_is_an_error_not_nothing_needed() {
        let p = phone(&Value::Null, None, Some(&infra(vec![])));
        assert_eq!(p.state, "warn");
        assert!(texts(&p, "needs").is_empty());
        assert!(texts(&p, "error")[0].starts_with("no fleet state yet"));
    }

    /// A card whose window, when it has one, is `delivered/committed` due 11-22.
    fn card(name: &str, window: Option<(u32, u32)>, running: usize, waiting: usize) -> Card {
        let r = crate::home::Running {
            slug: "s".into(),
            title: "t".into(),
            project: name.into(),
            started: None,
            target: None,
            phases: None,
            ..Default::default()
        };
        Card {
            name: name.into(),
            window: window.map(|(delivered, committed)| crate::projects::Window {
                due: Some("2026-11-22".into()),
                delivered,
                committed,
                ..Default::default()
            }),
            running: vec![r; running],
            waiting,
            ..Card::default()
        }
    }

    #[test]
    fn projects_head_counts_in_flight_then_names_the_first_two() {
        let p = Projects {
            cards: vec![
                card("agent-runtime", Some((21, 84)), 4, 1),
                card("unity-core-playground", Some((1, 71)), 9, 0),
                card("dodginballs", None, 4, 0),
                card("trader", Some((3, 105)), 1, 0),
                card("idle", None, 0, 0),
            ],
            ..Projects::default()
        };
        let mut p = p;
        p.cards[0].state = crate::projects::AT_RISK;
        p.cards[1].state = crate::projects::ON_TRACK;
        let levels: Vec<Level> = projects(&p).iter().map(|r| r.level).collect();
        assert_eq!(
            levels,
            [Level::Ok, Level::Warn, Level::Ok],
            "a row wears its state's hue"
        );
        let rows: Vec<String> = projects(&p).into_iter().map(|r| r.text).collect();
        assert_eq!(
            rows,
            vec![
                "Projects: 4 in flight of 5",
                "agent-runtime at risk, 21/84 due 11-22, 4 run, 1 wait",
                "unity-core-playground on track, 1/71 due 11-22, 9 run",
            ]
        );
        assert!(lint(&rows), "{rows:#?}");
    }

    #[test]
    fn a_busy_project_shortens_its_counts_so_waiting_still_shows() {
        let busy = project(&card("unity-core-playground", Some((1, 71)), 11, 1));
        assert_eq!(busy, "unity-core-playground 1/71 due 11-22, 11 run, 1 wait");
        // Only the name is cut, so the window survives a long one too.
        let long = project(&card(
            "unity-core-playground-extras-x",
            Some((1, 71)),
            11,
            1,
        ));
        assert_eq!(
            long,
            "unity-core-playground-... 1/71 due 11-22, 11 run, 1 wait"
        );
        let spaced = project(&card(&"word ".repeat(12), Some((1, 71)), 11, 1));
        assert!(
            spaced.ends_with("... 1/71 due 11-22, 11 run, 1 wait"),
            "{spaced}"
        );
        let waiting = project(&card("unity-core-playground", None, 0, 3));
        assert_eq!(waiting, "unity-core-playground no window, 3 waiting");
        for r in [&busy, &long, &spaced, &waiting] {
            assert!(r.chars().count() <= LINE_MAX, "{r}");
        }
        assert!(lint(&[busy, long, spaced, waiting]));
    }

    #[test]
    fn projects_with_nothing_in_flight_is_one_line_and_no_cards_is_none() {
        let p = Projects {
            cards: vec![card("idle", None, 0, 0)],
            ..Projects::default()
        };
        let rows: Vec<String> = projects(&p).into_iter().map(|r| r.text).collect();
        assert_eq!(rows, vec!["Projects: nothing in flight of 1"]);
        assert!(projects(&Projects::default()).is_empty());
    }

    #[test]
    fn build_carries_the_projects_rows_last() {
        let s = state();
        let h = home::build(Some(&s), None, None, None, NOW);
        let p = Projects {
            cards: vec![card("agent-runtime", Some((21, 84)), 1, 0)],
            ..Projects::default()
        };
        let out = build(
            &h,
            &Inputs {
                state: &s,
                queue: None,
                infra: None,
                projects: Some(&p),
                merged: None,
                now: NOW,
            },
        );
        assert_eq!(out.rows.last().unwrap().head, "projects");
        assert_eq!(texts(&out, "projects")[0], "Projects: 1 in flight of 1");
    }

    /// `comms-lint --channel phone` over `rows`, from the repo's own script and channels.
    fn lint(rows: &[String]) -> bool {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");
        let mut lint = Command::new(format!("{root}/.local/bin/comms-lint"))
            .args(["--channel", "phone", "-"])
            .env(
                "COMMS_CHANNELS",
                format!("{root}/.config/comms-lint/channels.toml"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let mut stdin = lint.stdin.take().unwrap();
        stdin.write_all(rows.join("\n").as_bytes()).unwrap();
        drop(stdin);
        lint.wait().unwrap().success()
    }

    #[test]
    fn the_rows_pass_the_phone_channel() {
        let (s, q) = (state(), queue_of(vec![(State::Running, "r1")]));
        let inf = infra(vec![("bench", bench())]);
        let rows: Vec<String> = phone(&s, Some(&q), Some(&inf))
            .rows
            .into_iter()
            .map(|r| r.text)
            .collect();
        assert!(lint(&rows), "{rows:#?}");
        // Negative control: a line past the budget fails, so the pass above means something.
        assert!(!lint(&["x ".repeat(80)]));
        // And so does one row past the line budget, since the widget clips at the bottom.
        assert!(!lint(&vec!["ok".to_string(); 15]));
    }

    #[test]
    fn ages_read_at_a_glance() {
        assert_eq!(age(2400), "40m");
        assert_eq!(age(5 * 3600), "5h");
        assert_eq!(age(47 * 3600), "47h");
        assert_eq!(age(3 * 86400), "3d");
    }
}
