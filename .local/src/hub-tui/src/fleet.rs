//! The Sessions tab's frame around the session table (controls.rs): the stage counts from
//! `fleet-sessions`' state document over it, and what waits on main, the open asks and the newest
//! lines of watch.log under it. It judges nothing: the bucket, the reason and every cell come
//! from fleet-sessions, as agent-web's Sessions tab reads them (`hub_core::boards`).

use chrono::{DateTime, Local, TimeZone};
use hub_core::boards::Watch;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use serde_json::Value;

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{older, Palette};

/// Changes listed under the table; watch.log keeps them all.
use hub_core::layout::FOLD_ROWS;

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
fn dash(x: &str) -> String {
    if x.is_empty() {
        "-".into()
    } else {
        x.into()
    }
}

/// Minutes as 45m, 3h12m, 2d4h, as the bash board's `dur`.
fn mins(m: Option<i64>) -> String {
    match m {
        None => "-".into(),
        Some(m) if m < 60 => format!("{m}m"),
        Some(m) if m < 1440 => format!("{}h{}m", m / 60, m % 60),
        Some(m) => format!("{}d{}h", m / 1440, m % 1440 / 60),
    }
}

/// Minutes rounded to 45m or 3h: a share of an age, not a clock; - for none.
fn hrs(m: i64) -> String {
    match m {
        ..=0 => "-".into(),
        1..=59 => format!("{m}m"),
        _ => format!("{}h", (m as f64 / 60.0).round() as i64),
    }
}

/// The SESSION column's width; a longer name keeps its tail.
pub const NAME_MAX: usize = 30;

/// The session name as the board shows it: no server, no `:1`, and a long one keeps its tail,
/// the part that tells sessions apart.
pub fn short(target: &str) -> String {
    let t = target.split_once('/').map_or(target, |(_, r)| r);
    let t = t.strip_suffix(":1").unwrap_or(t);
    let n = t.chars().count();
    if n <= NAME_MAX {
        return t.into();
    }
    let tail: String = t.chars().skip(n - (NAME_MAX - 1)).collect();
    match tail.split_once('-') {
        Some((_, r)) => format!("~{r}"),
        None => format!("~{tail}"),
    }
}

fn stage_style(p: Palette, b: &str) -> Style {
    match b {
        "NEEDS" | "STALLED" => p.bad(),
        "DONE" => p.good(),
        "LANDED" => p.warn(),
        _ => Style::new(),
    }
}

pub fn ci_style(p: Palette, c: &str) -> Style {
    match c {
        "fail" | "failure" => p.bad(),
        "pass" | "success" => p.good(),
        "pending" => p.warn(),
        _ => Style::new(),
    }
}

/// The name of each of row()'s cells.
pub const HEAD: [&str; 17] = [
    "SESSION",
    "TASK",
    "STAGE",
    "SYNC",
    "CONFLICTS",
    "TREE",
    "PR",
    "PRS",
    "CI",
    "PLAN",
    "ETA",
    "WORK",
    "WAIT",
    "IDLE",
    "AGE",
    "LABELS",
    "WHY",
];

/// Every cell fleet-sessions keeps for a session, from its state-document object.
pub fn row(x: &Value, p: Palette) -> Vec<Cell> {
    let git = s(x, "branch") != "-" && !s(x, "branch").is_empty();
    let n = |k: &str| x[k].as_i64();
    let sync = match (git, n("behind")) {
        (true, Some(0)) => "current".into(),
        (true, Some(b)) => format!("{b} behind"),
        _ => "-".into(),
    };
    let conflicts = match (git, x["conflicts"].as_bool()) {
        (true, Some(true)) => cell("CONFLICT", p.bad()),
        (true, Some(false)) => "no".into(),
        _ => "-".into(),
    };
    let tree = match (git, n("dirty"), n("ahead")) {
        (false, ..) => "-".into(),
        (_, Some(d), _) if d > 0 => format!("{d} dirty"),
        (_, _, Some(a)) if a > 0 => format!("{a} ahead"),
        _ => "clean".into(),
    };
    let pr = match s(x, "pr") {
        "" | "-" => "-".into(),
        num => format!("#{num} {}", s(x, "pr_state").to_lowercase())
            .trim_end()
            .to_string(),
    };
    let prs = x["prs"].as_array().filter(|a| !a.is_empty()).map(|a| {
        let merged = a.iter().filter(|r| r["state"] == "MERGED").count();
        let unknown = a.iter().any(|r| r["state"].is_null());
        format!("{merged}/{}{}", a.len(), if unknown { "?" } else { "" })
    });
    let ci = s(x, "ci").to_lowercase();
    let plan = match (n("phases_done"), n("phases_total")) {
        (Some(d), Some(t)) => format!("{d}/{t}"),
        _ => "-".into(),
    };
    let t = &x["time"];
    let tm = |k: &str| t[k].as_i64().unwrap_or(0);
    let wait = [
        ("gate", tm("gate_min")),
        ("test", tm("test_min")),
        ("jobs", tm("jobs_min")),
        ("you", tm("human_min")),
        ("parked", tm("parked_min")),
    ]
    .into_iter()
    .fold(None, |best: Option<(&str, i64)>, (k, v)| match best {
        Some((_, b)) if b >= v => best,
        _ if v > 0 => Some((k, v)),
        _ => best,
    })
    .map_or("-".into(), |(k, v)| format!("{k} {}", hrs(v)));
    let bucket = s(x, "bucket");
    let doing = s(x, "doing");
    let why = if bucket == "WORKING" && !doing.is_empty() {
        doing.strip_prefix("Bash: ").unwrap_or(doing).to_string()
    } else {
        s(x, "reason").to_string()
    };
    let labels: Vec<&str> = x["labels"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    vec![
        short(s(x, "target")).into(),
        dash(s(x, "topic")).into(),
        cell(bucket, stage_style(p, bucket)),
        sync.into(),
        conflicts,
        tree.into(),
        pr.into(),
        prs.unwrap_or_else(|| "-".into()).into(),
        cell(dash(&ci), ci_style(p, &ci)),
        plan.into(),
        dash(s(x, "eta")).into(),
        hrs(tm("work_min")).into(),
        wait.into(),
        mins(n("idle_min")).into(),
        mins(n("age_min")).into(),
        dash(&labels.join(",")).into(),
        why.into(),
    ]
}

fn ago(ts: i64, now: i64) -> String {
    mins(Some((now - ts).max(0) / 60))
}

/// The whole tab, top to bottom, with the session table in its place under the counts.
pub fn page(
    watch: &Watch,
    table: Vec<Line<'static>>,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let st = &watch.state;
    let mut out = vec![];
    if st.is_null() {
        out.push(Line::styled(
            "No fleet state document yet. fleet-state.timer writes it every minute: systemctl --user status fleet-state.timer",
            p.warn(),
        ));
        out.extend(table);
    } else {
        let at = st["generated_epoch"].as_i64().unwrap_or(0);
        out.push(Line::styled(
            format!("SESSIONS   state {} old", ago(at, now)),
            if now - at > 300 { p.warn() } else { p.dim() },
        ));
        out.extend(table);
        if let Some(u) = st["unreadable"].as_array().filter(|u| !u.is_empty()) {
            let names: Vec<&str> = u.iter().filter_map(Value::as_str).collect();
            out.push(Line::styled(
                format!(
                    "could not read {} on the last pass: its cells are the last good ones",
                    names.join(", ")
                ),
                p.warn(),
            ));
        }

        if let Some(main) = st["main"].as_array().filter(|m| !m.is_empty()) {
            out.push(Line::raw(""));
            out.push(Line::styled("NIGHTLY", p.head()));
            for m in main {
                out.push(clip_line(
                    Line::styled(format!("  {}", s(m, "reason")), p.bad()),
                    w,
                ));
            }
        }

        let asks: Vec<&Value> = st["asks"]
            .as_array()
            .map(|a| a.iter().collect())
            .unwrap_or_default();
        out.push(Line::raw(""));
        out.push(Line::styled(format!("ASKS ({})", asks.len()), p.head()));
        if asks.is_empty() {
            out.push(Line::styled("  nothing waits on you", p.dim()));
        } else {
            let t = Table {
                mark: None,
                header: vec!["ID", "PROJECT", "AGE", "SESSION", "QUESTION"],
                rows: asks
                    .iter()
                    .map(|a| {
                        let age = DateTime::parse_from_str(s(a, "created"), "%Y-%m-%dT%H:%M:%S%z")
                            .map_or("-".into(), |t| ago(t.timestamp(), now));
                        vec![
                            s(a, "id").into(),
                            s(a, "project").into(),
                            age.into(),
                            a["session"].as_str().map_or("-".into(), short).into(),
                            s(a, "question").replace(['\n', '\t'], " ").into(),
                        ]
                    })
                    .collect(),
                keep: vec![0, 1, 2, 3],
                flex: Some(4),
                flexmin: 20,
                flexkeep: true,
                right: vec![2],
                cap: vec![(1, 22), (3, 28)],
            };
            out.extend(t.fit(w, p.head()));
        }
    }

    out
}

/// Log's Changes section: watch.log's transitions, newest first, at most `FOLD_ROWS`.
pub fn changes(watch: &Watch, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if watch.transitions.is_empty() {
        out.push(Line::styled("  none logged yet", p.dim()));
    }
    let today = Local
        .timestamp_opt(now, 0)
        .single()
        .map(|t| t.format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    for t in watch.transitions.iter().rev().take(FOLD_ROWS) {
        let when = match t.ts.split_once(' ') {
            Some((d, hm)) if d == today => hm.to_string(),
            _ => t.ts.get(5..).unwrap_or(&t.ts).to_string(),
        };
        let style = match t.to.as_deref() {
            Some(b) => stage_style(p, b),
            None if t.kind == "gone" => p.dim(),
            None => Style::new(),
        };
        out.push(clip_line(
            Line::from(vec![
                Span::styled(format!("  {when:<11} "), p.dim()),
                Span::raw(format!("{}  ", short(&t.target))),
                Span::styled(t.text.clone(), style),
            ]),
            w,
        ));
    }
    out.extend(older(watch.transitions.len(), FOLD_ROWS, p));
    out
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::boards::parse_transition;

    pub fn fixture() -> Watch {
        let state = serde_json::json!({
            "schema": 1, "generated_epoch": 1_000_000, "unreadable": [],
            "sessions": [
                {"bucket": "WORKING", "target": "lab/unity-core-playground-agent-10:1",
                 "branch": "feat/x", "pr": "1645", "pr_state": "OPEN", "ci": "PENDING",
                 "behind": 3, "conflicts": false, "dirty": 0, "ahead": 2,
                 "phases_done": 1, "phases_total": 4, "idle_min": 2, "age_min": 95,
                 "reason": "busy", "doing": "Bash: cargo test", "topic": "bench press",
                 "labels": [], "prs": [{"state": "MERGED"}, {"state": "OPEN"}],
                 "time": {"work_min": 80, "gate_min": 0, "test_min": 10, "jobs_min": 0,
                          "human_min": 0, "parked_min": 0}, "eta": "21:30 s3"},
                {"bucket": "NEEDS", "target": "hub/dotfiles:1", "branch": "main", "pr": "-",
                 "behind": 0, "conflicts": false, "dirty": 0, "ahead": 0, "idle_min": 2,
                 "age_min": 23, "reason": "1 pending ask(s)", "labels": [], "prs": [],
                 "time": {"work_min": 6, "human_min": 14}}
            ],
            "main": [{"repo": "unity-core-playground", "reason": "unity-core-playground red: Shots"}],
            "asks": [{"id": "ggK2ey", "project": "dotfiles", "question": "rename?",
                      "created": "2026-11-03T12:00:00-0800", "session": "dotfiles"}]
        });
        Watch {
            state,
            transitions: [
                "2026-11-03 11:50  hub/dotfiles:1  new: NEEDS (1 pending ask(s))",
                "2026-11-03 12:06  lab/unity-core-playground-agent-10:1  stage NEEDS -> WORKING (busy)",
            ]
            .iter()
            .filter_map(|l| parse_transition(l))
            .collect(),
        }
    }

    fn text(lines: &[Line]) -> String {
        lines.iter().map(plain).collect::<Vec<_>>().join("\n")
    }

    /// The page as the Sessions tab draws it: the fixture's sessions in the session table.
    fn page(watch: &Watch, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        let mut c = crate::controls::Controls::default();
        c.read(watch.state["sessions"].as_array().cloned(), None);
        super::page(watch, c.lines(p, now, w), p, now, w)
    }

    #[test]
    fn needs_sorts_first_and_working_rows_say_what_they_are_doing() {
        let p = Palette { no_color: true };
        let out = text(&page(&fixture(), p, 1_000_000 + 120, 240));
        let dot = out.find("dotfiles  ").unwrap();
        let agent = out.find("unity-core-playground-agent-10").unwrap();
        assert!(dot < agent, "{out}");
        assert!(out.contains("SESSIONS   state 2m old"), "{out}");
        assert!(
            out.contains("cargo test") && !out.contains("Bash: cargo"),
            "{out}"
        );
        assert!(
            out.contains("#1645 open PENDING") && out.contains("1/4") && out.contains("21:30 s3")
        );
        assert!(out.contains("unity-core-playground red: Shots"), "{out}");
        assert!(out.contains("ggK2ey") && out.contains("rename?"));
    }

    #[test]
    fn changes_are_newest_first() {
        let p = Palette { no_color: true };
        let out = text(&changes(&fixture(), p, 1_000_000, 160));
        let a = out.find("stage NEEDS -> WORKING").unwrap();
        let b = out.find("new: NEEDS").unwrap();
        assert!(a < b, "{out}");
        let sessions = text(&page(&fixture(), p, 1_000_000, 160));
        assert!(!sessions.contains("new: NEEDS"), "{sessions}");
    }

    #[test]
    fn a_narrow_pane_keeps_session_and_stage() {
        let p = Palette { no_color: true };
        let out = page(&fixture(), p, 1_000_000, 40);
        for l in &out {
            assert!(unicode_width::UnicodeWidthStr::width(plain(l).as_str()) <= 40);
        }
        let t = text(&out);
        assert!(t.contains("SESSION") && t.contains("STAGE"), "{t}");
    }

    #[test]
    fn no_state_document_says_who_writes_it() {
        let w = Watch {
            state: Value::Null,
            transitions: vec![],
        };
        let t = text(&page(&w, Palette { no_color: true }, 0, 200));
        assert!(t.contains("fleet-state.timer"), "{t}");
    }

    #[test]
    fn long_names_keep_their_tail() {
        assert_eq!(short("hub/dotfiles:1"), "dotfiles");
        assert_eq!(short("lab/dotfiles:3"), "dotfiles:3");
        let s = short("lab/unity-core-playground-very-long-agent-name-47:1");
        assert!(s.starts_with('~') && s.ends_with("agent-name-47"), "{s}");
    }
}
