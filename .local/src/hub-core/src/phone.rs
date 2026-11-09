//! The phone widget's rows: `hub phone --json`, published by `agent-mqtt-publish` and laid out by
//! home-config's `phone_widget.jinja`. Plain text and a level, no markup, so the layout lives in
//! one place. Needs come from `home::Home`, so the phone and the hub count the same rows; the
//! phone counts the live waits among them (asks, sessions, queue items), not the sheet rows.
//!
//! The System block is not here: it is read in the cluster, so it still shows with this machine off.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::home::{Home, Kind, Level, Need};
use crate::infra::Infra;
use crate::projects::{Card, Projects};
use crate::queue::{day_of, Queue, State};
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

fn needs(waiting: &[&Need], now: i64) -> Vec<Row> {
    if waiting.is_empty() {
        return vec![row(Level::Ok, "needs", "Needs you: nothing")];
    }
    let of = |k: Kind| waiting.iter().filter(|n| n.kind == k).count();
    let split = counted(&[
        (of(Kind::Ask), "ask", "asks"),
        (of(Kind::Session), "session", "sessions"),
        (of(Kind::Queue), "queue item", "queue items"),
    ]);
    let mut out = vec![row(
        Level::Warn,
        "needs",
        format!("Needs you: {} ({split})", waiting.len()),
    )];

    let mut by: BTreeMap<&str, usize> = BTreeMap::new();
    for n in waiting {
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

    if let Some((since, n)) = waiting
        .iter()
        .filter_map(|n| n.since.map(|s| (s, n)))
        .min_by_key(|(s, _)| *s)
    {
        let line = format!("oldest {}: {}", age(now - since), cap(&n.text, ASK_MAX));
        out.push(row(Level::Ok, "needs", line));
    }
    out
}

/// "14 late (worst 21h), next done 10:12", from the sessions still live.
fn etas(state: &Value, now: i64) -> Option<String> {
    let vocab = Vocab::from_state(state);
    let etas: Vec<i64> = state["sessions"]
        .as_array()?
        .iter()
        .filter(|s| vocab.in_progress(s["bucket"].as_str().unwrap_or("")))
        .filter_map(|s| s["eta_epoch"].as_i64())
        .collect();
    let late: Vec<i64> = etas.iter().copied().filter(|e| *e < now).collect();
    let mut said = vec![];
    if let Some(oldest) = late.iter().min() {
        said.push(format!("{} late (worst {})", late.len(), age(now - oldest)));
    }
    if let Some(next) = etas.iter().filter(|e| **e >= now).min() {
        let at = chrono::DateTime::from_timestamp(*next, 0)?.with_timezone(&chrono::Local);
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

/// "Done today: 42 queue items, 33 PRs merged", then one line per project, busiest first:
/// "unity-core-playground 38 items, 25 PRs", the last ending ", +3 more" when there are others. Queue items done are the ok ones finished since local
/// midnight and PRs come from the day-log, so each source counts only when it could be read; with
/// neither there is no section.
fn done(i: &Inputs) -> Vec<Row> {
    let today = chrono::DateTime::from_timestamp(i.now, 0).map(|t| {
        t.with_timezone(&chrono::Local)
            .format("%Y-%m-%d")
            .to_string()
    });
    let items: Option<Vec<&str>> = i.queue.map(|q| {
        q.items
            .iter()
            .filter(|x| x.state == State::Done && x.status.as_deref() == Some("ok"))
            .filter(|x| x.finished.as_deref().and_then(day_of) == today)
            .map(|x| {
                if x.project.is_empty() {
                    "other"
                } else {
                    repo(&x.project)
                }
            })
            .collect()
    });
    let prs = i.merged.as_ref();
    if items.is_none() && prs.is_none() {
        return vec![];
    }
    let plural =
        |n: usize, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
    let mut head = vec![];
    if let Some(v) = &items {
        head.push(plural(v.len(), "queue item", "queue items"));
    }
    if let Some(v) = prs {
        head.push(plural(v.len(), "PR merged", "PRs merged"));
    }
    let mut out = vec![row(
        Level::Ok,
        "done",
        format!("Done today: {}", head.join(", ")),
    )];

    let mut by: BTreeMap<&str, (usize, usize)> = BTreeMap::new();
    for p in items.iter().flatten() {
        by.entry(p).or_default().0 += 1;
    }
    for p in prs.into_iter().flatten() {
        by.entry(repo(p)).or_default().1 += 1;
    }
    let mut by: Vec<(&str, (usize, usize))> = by.into_iter().collect();
    by.sort_by_key(|(name, (n, m))| (std::cmp::Reverse(n + m), *name));
    let shown = by.len().min(DONE_PROJECTS);
    for (k, (name, (n, m))) in by.iter().take(shown).enumerate() {
        // The fold rides on the last row, so the section stays a head and `DONE_PROJECTS` lines.
        let fold = if k + 1 == shown && by.len() > shown {
            format!(", +{} more", by.len() - shown)
        } else {
            String::new()
        };
        let tail = format!(
            " {}{fold}",
            counted(&[(*n, "item", "items"), (*m, "PR", "PRs")])
        );
        let room = LINE_MAX.saturating_sub(tail.chars().count());
        out.push(row(Level::Ok, "done", format!("{}{tail}", cap(name, room))));
    }
    out
}

/// "Queue: 14 running, 16 ready, 83 held", then one detail line: the oldest ready item's wait and
/// what a PR costs, "oldest ready waited 37h, $4.24 per PR (28d $5.90)". What the queue delivered
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
            said.push(format!("oldest ready waited {}", age(o.minutes * 60)));
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

/// One card as the widget says it: "agent-runtime 35%, ETA 69d, 4 running". Past `LINE_MAX` the
/// counts shorten to "11 run, 1 wait", and then only the name is capped, so the percent, ETA and
/// counts always show.
fn project(c: &Card) -> String {
    let eta = match c.eta_days {
        Some(0) => ", nothing open".to_string(),
        Some(d) => format!(", ETA {d}d"),
        None => ", no ETA".to_string(),
    };
    let rest = |run: &str, wait: &str| {
        let mut s = format!(" {}%{eta}", c.percent.unwrap_or(0));
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
    out.extend(
        flying
            .iter()
            .take(CARDS)
            .map(|c| row(Level::Ok, "projects", project(c))),
    );
    out
}

/// "CI: 6/29 busy, 79% passed, aws-burst-1 offline": the pools summed, naming only what is down.
fn ci(infra: &Infra) -> Option<Row> {
    let v = infra.cc_values();
    let sum = |name: &str| -> f64 {
        v.iter()
            .filter(|(k, _)| k.strip_prefix(name).is_some_and(|r| r.starts_with('/')))
            .map(|(_, x)| *x)
            .sum()
    };
    let slots = sum("cc:pool_slots");
    if slots == 0.0 {
        return None;
    }
    let mut said = vec![format!("CI: {:.0}/{slots:.0} busy", sum("cc:pool_busy"))];
    let queued = sum("cc:pool_waiting");
    if queued > 0.0 {
        said.push(format!("{queued:.0} queued"));
    }
    let (mut done, mut passed) = (0.0, 0.0);
    for (k, ratio) in &v {
        if let Some(pool) = k.strip_prefix("cc:pool_pass_ratio_24h/") {
            let d = v
                .get(&format!("cc:pool_done_24h/{pool}"))
                .copied()
                .unwrap_or(0.0);
            done += d;
            passed += d * ratio;
        }
    }
    if done > 0.0 {
        said.push(format!("{:.0}% passed", passed / done * 100.0));
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
    let nightly: Vec<&str> = home
        .needs
        .iter()
        .filter(|n| n.kind == Kind::Nightly)
        .map(|n| repo(&n.project))
        .collect();
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
    let waiting: Vec<&Need> = home
        .needs
        .iter()
        .filter(|n| matches!(n.kind, Kind::Ask | Kind::Session | Kind::Queue))
        .collect();
    if !i.state.is_null() {
        rows.extend(needs(&waiting, i.now));
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
    Phone { state, rows }
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
    Some(
        merged
            .iter()
            .map(|m| match m["project"].as_str() {
                Some(p) if !p.is_empty() => p.to_string(),
                _ => "other".to_string(),
            })
            .collect(),
    )
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
            series(vec![
                metric("cc:overall_status", json!({}), "0"),
                metric("cc:pool_slots", json!({"pool": "unity"}), "10"),
                metric("cc:pool_slots", json!({"pool": "light"}), "19"),
                metric("cc:pool_busy", json!({"pool": "unity"}), "6"),
                metric("cc:pool_done_24h", json!({"pool": "unity"}), "100"),
                metric("cc:pool_pass_ratio_24h", json!({"pool": "unity"}), "0.5"),
                metric("cc:pool_done_24h", json!({"pool": "light"}), "300"),
                metric("cc:pool_pass_ratio_24h", json!({"pool": "light"}), "0.9"),
            ]),
        );
        for (k, rows) in extra {
            inf.instant.insert(k, series(rows));
        }
        crate::infra::judge(&mut inf, vec![]);
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
                 "created": "2027-01-14T10:00:00-0800", "session": "s1"},
                {"id": "aB2", "project": ".dotfiles", "question": "Keep it?", "session": ""},
            ],
            "main": [{"repo": ".dotfiles", "reason": "red"}],
            "vocab": {"buckets": ["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"],
                      "in_progress": ["WORKING", "NEEDS", "STALLED"]},
            "sessions": [
                {"target": "w/s2:1", "bucket": "WORKING", "cwd": "/x/trader", "eta_epoch": NOW - 7200},
                {"target": "w/s3:1", "bucket": "NEEDS", "cwd": "/x/trader", "idle_min": 30,
                 "reason": "permission", "eta_epoch": NOW - 3600},
                {"target": "w/s4:1", "bucket": "WORKING", "cwd": "/x/y", "eta_epoch": NOW + 600},
                {"target": "w/s5:1", "bucket": "DONE", "cwd": "/x/y", "eta_epoch": NOW - 90000},
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
        let h = home::build(state, q, None, inf);
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
        let shown = home::build(&s, Some(&q), None, Some(&inf))
            .needs
            .iter()
            .filter(|n| matches!(n.kind, Kind::Ask | Kind::Session | Kind::Queue))
            .count();
        let needs = texts(&p, "needs");
        assert_eq!(shown, 4);
        assert_eq!(needs[0], "Needs you: 4 (2 asks, 1 session, 1 queue item)");
        assert!(needs[1].starts_with("dotfiles 1"), "{}", needs[1]);
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
                format!("2 late (worst 2h), next done {next}"),
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
    fn the_queue_says_ready_held_and_how_long_the_oldest_waited() {
        let mut q = queue_of(vec![
            (State::Running, "r1"),
            (State::Queued, "q1"),
            (State::Queued, "q2"),
        ]);
        q.items[2].hold = Some("after q1".into());
        q.stats = Some(crate::queue::Stats {
            sitting: Some(crate::queue::Sitting {
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
                "Queue: 1 running, 1 ready, 1 held",
                "oldest ready waited 37h, $6.54 per PR (28d $7.00)",
            ]
        );
    }

    #[test]
    fn done_leads_with_the_day_per_project_and_counts_only_what_was_read() {
        let mut q = queue_of(vec![(State::Running, "r1")]);
        // Every finish is NOW itself, so the machine's timezone cannot move one across midnight.
        q.items.push(done_item("a", "agent-runtime", NOW));
        q.items.push(done_item("b", "agent-runtime", NOW));
        q.items.push(done_item("c", ".dotfiles", NOW));
        q.items
            .push(done_item("old", "agent-runtime", NOW - 3 * 86400));
        let mut failed = done_item("bad", "agent-runtime", NOW);
        failed.status = Some("failed".into());
        q.items.push(failed);
        let p = phone(&state(), Some(&q), Some(&infra(vec![])));
        assert_eq!(
            texts(&p, "done"),
            [
                "Done today: 3 queue items, 85 PRs merged",
                "unity-core-playground 57 PRs",
                "dotfiles 1 item, 28 PRs, +1 more",
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
        let h = home::build(&state(), Some(&q), None, None);
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
                "Done today: 15 queue items",
                "e 5 items",
                "d 4 items, +3 more",
            ]
        );
    }

    #[test]
    fn done_is_absent_when_neither_source_could_be_read() {
        let h = home::build(&state(), None, None, None);
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
    fn ci_sums_the_pools_and_names_only_what_is_down() {
        let runners = vec![
            metric("x", json!({"host": "aws-burst-1", "state": "offline"}), "0"),
            metric("x", json!({"host": "aws-burst-1", "state": "offline"}), "0"),
            metric("x", json!({"host": "box", "state": "idle"}), "1"),
        ];
        let inf = infra(vec![("runners", runners.clone())]);
        let p = phone(&state(), None, Some(&inf));
        assert_eq!(
            texts(&p, "ci"),
            ["CI: 6/29 busy, 80% passed, aws-burst-1 offline"]
        );
        // Powered off by the governor, its runners are offline by design: nothing is down.
        let stopped = metric(
            "ci_governor_power_state",
            json!({"host": "aws-burst-1", "state": "stopped"}),
            "1",
        );
        let inf = infra(vec![("runners", runners), ("power", vec![stopped])]);
        let p = phone(&state(), None, Some(&inf));
        assert_eq!(texts(&p, "ci"), ["CI: 6/29 busy, 80% passed"]);
    }

    #[test]
    fn an_all_green_fleet_is_one_line_a_section() {
        let s = json!({"counts": {"WORKING": 2}, "asks": [], "main": [], "sessions": []});
        let q = queue_of(vec![(State::Running, "r1")]);
        let inf = infra(vec![]);
        let p = phone(&s, Some(&q), Some(&inf));
        assert_eq!(p.state, "ok");
        assert_eq!(
            p.rows.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            [
                "Needs you: nothing",
                "Done today: 0 queue items, 85 PRs merged",
                "unity-core-playground 57 PRs",
                "dotfiles 28 PRs",
                "Agents: 2 working",
                "Queue: 1 running, 0 ready",
                "CI: 6/29 busy, 80% passed",
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

    fn card(name: &str, percent: u32, eta: Option<u32>, running: usize, waiting: usize) -> Card {
        let r = crate::home::Running {
            slug: "s".into(),
            title: "t".into(),
            project: name.into(),
            started: None,
            target: None,
            phases: None,
        };
        Card {
            name: name.into(),
            percent: Some(percent),
            eta_days: eta,
            running: vec![r; running],
            waiting,
            ..Card::default()
        }
    }

    #[test]
    fn projects_head_counts_in_flight_then_names_the_first_two() {
        let p = Projects {
            cards: vec![
                card("agent-runtime", 35, Some(69), 4, 1),
                card("unity-core-playground", 52, Some(54), 9, 0),
                card("dodginballs", 2, None, 4, 0),
                card("trader", 49, Some(40), 1, 0),
                card("idle", 66, None, 0, 0),
            ],
            ..Projects::default()
        };
        let rows: Vec<String> = projects(&p).into_iter().map(|r| r.text).collect();
        assert_eq!(
            rows,
            vec![
                "Projects: 4 in flight of 5",
                "agent-runtime 35%, ETA 69d, 4 running, 1 waiting",
                "unity-core-playground 52%, ETA 54d, 9 running",
            ]
        );
        assert!(lint(&rows), "{rows:#?}");
    }

    #[test]
    fn a_busy_project_shortens_its_counts_so_waiting_still_shows() {
        let busy = project(&card("unity-core-playground", 52, Some(54), 11, 1));
        assert_eq!(busy, "unity-core-playground 52%, ETA 54d, 11 run, 1 wait");
        // Only the name is cut, so the percent and ETA survive a long one too.
        let long = project(&card("unity-core-playground-extras-x", 52, Some(54), 11, 1));
        assert_eq!(
            long,
            "unity-core-playground-ex... 52%, ETA 54d, 11 run, 1 wait"
        );
        let spaced = project(&card(&"word ".repeat(12), 52, Some(54), 11, 1));
        assert!(
            spaced.ends_with("... 52%, ETA 54d, 11 run, 1 wait"),
            "{spaced}"
        );
        let waiting = project(&card("unity-core-playground", 52, None, 0, 3));
        assert_eq!(waiting, "unity-core-playground 52%, no ETA, 3 waiting");
        for r in [&busy, &long, &spaced, &waiting] {
            assert!(r.chars().count() <= LINE_MAX, "{r}");
        }
        assert!(lint(&[busy, long, spaced, waiting]));
    }

    #[test]
    fn projects_with_nothing_in_flight_is_one_line_and_no_cards_is_none() {
        let p = Projects {
            cards: vec![card("idle", 66, None, 0, 0)],
            ..Projects::default()
        };
        let rows: Vec<String> = projects(&p).into_iter().map(|r| r.text).collect();
        assert_eq!(rows, vec!["Projects: nothing in flight of 1"]);
        assert!(projects(&Projects::default()).is_empty());
    }

    #[test]
    fn build_carries_the_projects_rows_last() {
        let s = state();
        let h = home::build(&s, None, None, None);
        let p = Projects {
            cards: vec![card("agent-runtime", 35, Some(69), 1, 0)],
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
