//! The Today and History tabs: what a day shipped, from the records `day-log snapshot` writes
//! to `~/.agent/daylog/<date>.json` (day-log.timer, every 5 minutes). The sections are the ones
//! `day-log show` prints; the record's fields are read as written, nothing is recomputed.

use chrono::{DateTime, Local, Timelike};
use hub_core::boards::DayRow;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use serde_json::Value;

use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::Palette;

/// Open PRs touched within this many days are listed; older ones are counted (`DAYLOG_OPEN_DAYS`).
pub const OPEN_DAYS: i64 = 7;

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
fn or_dash(x: &str) -> String {
    if x.is_empty() {
        "-".into()
    } else {
        x.into()
    }
}

fn local(ts: &str) -> Option<DateTime<Local>> {
    DateTime::parse_from_rfc3339(ts)
        .ok()
        .map(|t| t.with_timezone(&Local))
}

/// A timestamp as the local HH:MM, as day-log's `hm`.
fn hm(ts: &str) -> String {
    match local(ts) {
        Some(t) => t.format("%H:%M").to_string(),
        None => ts.get(11..16).unwrap_or("-").to_string(),
    }
}

/// A PR title without its conventional-commit prefix.
fn subject(title: &str) -> &str {
    let t = title.trim_start();
    let head: String = t.chars().take_while(|c| c.is_ascii_lowercase()).collect();
    if head.is_empty() {
        return t;
    }
    let mut rest = &t[head.len()..];
    if rest.starts_with('(') {
        match rest.find(')') {
            Some(i) => rest = &rest[i + 1..],
            None => return t,
        }
    }
    rest = rest.strip_prefix('!').unwrap_or(rest);
    match rest.strip_prefix(':') {
        Some(r) => r.trim_start(),
        None => t,
    }
}

pub fn money(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("${v:.2}"))
}

pub fn tok(v: Option<u64>) -> String {
    match v {
        None => "-".into(),
        Some(n) if n >= 1_000_000_000 => format!("{:.1}B", (n / 100_000_000) as f64 / 10.0),
        Some(n) if n >= 1_000_000 => format!("{:.1}M", (n / 100_000) as f64 / 10.0),
        Some(n) => n.to_string(),
    }
}

/// Touched within OPEN_DAYS of `now`.
fn recent(pr: &Value, now: i64) -> bool {
    DateTime::parse_from_rfc3339(s(pr, "updated_at"))
        .is_ok_and(|t| t.timestamp() >= now - OPEN_DAYS * 86400)
}

/// Sessions, cost and tokens: the `TOTAL` usage row, or the rows summed when there is none.
fn spend(rec: &Value) -> (Option<u64>, Option<f64>, Option<u64>) {
    let u = rec["usage"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    if let Some(t) = u.iter().find(|r| r["project"] == "TOTAL") {
        return (
            t["sessions"].as_u64(),
            t["cost_usd"].as_f64(),
            t["tokens"].as_u64(),
        );
    }
    (
        Some(u.iter().filter_map(|r| r["sessions"].as_u64()).sum()),
        Some(u.iter().filter_map(|r| r["cost_usd"].as_f64()).sum()),
        Some(u.iter().filter_map(|r| r["tokens"].as_u64()).sum()),
    )
}

/// The Today tab and where each section starts (for n/N).
pub struct Page {
    pub lines: Vec<Line<'static>>,
    pub sections: Vec<usize>,
}

pub fn today(rec: Option<&Value>, p: Palette, now: i64, w: usize) -> Page {
    let Some(rec) = rec else {
        return Page {
            lines: vec![Line::styled(
                "No day record yet. day-log.timer writes one every 5 minutes: systemctl --user status day-log.timer",
                p.warn(),
            )],
            sections: vec![],
        };
    };
    let mut out: Vec<Line<'static>> = vec![];
    let mut sections = vec![];
    let date = s(rec, "date");
    let day = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .map_or(date.to_string(), |d| d.format("%a %Y-%m-%d").to_string());
    let live = rec["live"].as_bool().unwrap_or(false);
    let gathered = s(rec, "gathered_at");
    let mut head = vec![Span::styled(format!("DAY  {day}  "), p.head())];
    head.push(if live {
        let old = local(gathered).map_or(0, |t| now - t.timestamp());
        Span::styled(
            format!("live, gathered {}", hm(gathered)),
            if old > 900 { p.warn() } else { p.dim() },
        )
    } else {
        Span::styled(
            format!(
                "past day, last gathered {}",
                gathered.get(..16).unwrap_or(gathered).replace('T', " ")
            ),
            p.dim(),
        )
    });
    if let Some(u) = rec["unreadable"].as_array().filter(|u| !u.is_empty()) {
        let names: Vec<&str> = u.iter().filter_map(Value::as_str).collect();
        head.push(Span::styled(
            format!("  could not read: {}", names.join(", ")),
            p.warn(),
        ));
    }
    out.push(clip_line(Line::from(head), w));

    let merged: Vec<&Value> = rec["merged"]
        .as_array()
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let mut repos: Vec<&str> = merged.iter().map(|m| s(m, "repo")).collect();
    repos.sort_unstable();
    repos.dedup();
    let open = rec["open"].as_array();
    let (sessions, cost, tokens) = spend(rec);
    let mut items = vec![format!("merged {} in {} repos", merged.len(), repos.len())];
    if let Some(o) = open {
        let fresh = o.iter().filter(|x| recent(x, now)).count();
        items.push(format!("open {fresh} (+{} older)", o.len() - fresh));
    }
    items.push(format!(
        "{} sessions {}",
        sessions.map_or("-".into(), |n| n.to_string()),
        money(cost)
    ));
    items.push(format!("{} tokens", tok(tokens)));
    if let Some(f) = rec["fleet"].as_object() {
        let mut b: Vec<(&String, i64)> = f
            .get("buckets")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .map(|(k, v)| (k, v.as_i64().unwrap_or(0)))
                    .collect()
            })
            .unwrap_or_default();
        b.sort_by(|x, y| y.1.cmp(&x.1).then(x.0.cmp(y.0)));
        let mut fl: Vec<String> = b.iter().map(|(k, v)| format!("{k} {v}")).collect();
        fl.push(format!(
            "unity runs {}",
            f.get("unity_runs").and_then(Value::as_i64).unwrap_or(0)
        ));
        items.push(format!("fleet {}", fl.join(" ")));
        for h in f
            .get("holds")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            items.push(format!(
                "HOLD {} since {} by {}",
                s(h, "resource"),
                hm(s(h, "since")),
                s(h, "by")
            ));
        }
    }
    out.extend(
        wrap(&items, "  ", w)
            .into_iter()
            .map(|l| clip_line(Line::raw(l), w)),
    );

    // Merges per local hour, first to last hour with one.
    let mut per = [0usize; 24];
    for m in &merged {
        if let Some(t) = local(s(m, "merged_at")) {
            per[t.hour() as usize] += 1;
        }
    }
    if let (Some(a), Some(b)) = (
        per.iter().position(|n| *n > 0),
        per.iter().rposition(|n| *n > 0),
    ) {
        let hours: String = (a..=b).map(|h| format!(" {h:02}")).collect();
        let counts: String = (a..=b)
            .map(|h| match per[h] {
                0 => "  .".to_string(),
                n => format!("{n:>3}"),
            })
            .collect();
        out.push(clip_line(
            Line::styled(format!("hour  {hours}"), p.dim()),
            w,
        ));
        out.push(clip_line(Line::raw(format!("merged{counts}")), w));
    }

    let mut section = |out: &mut Vec<Line<'static>>, title: String| {
        out.push(Line::raw(""));
        sections.push(out.len());
        out.push(Line::styled(title, p.head()));
    };

    // WAITING ON YOU
    let wt = &rec["waiting"];
    let list = |k: &str| wt[k].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let (main, needs, asks) = (list("main"), list("needs"), list("asks"));
    section(
        &mut out,
        format!("WAITING ON YOU ({})", main.len() + needs.len() + asks.len()),
    );
    let mut rows: Vec<Vec<Cell>> = vec![];
    for m in main {
        let r = s(m, "reason");
        let r = r
            .split_once(" red: ")
            .map_or(r.to_string(), |(_, x)| format!("red: {x}"));
        rows.push(vec![
            cell("NIGHTLY", p.bad()),
            s(m, "repo").into(),
            r.into(),
        ]);
    }
    for n in needs {
        rows.push(vec![
            cell("NEEDS", p.warn()),
            s(n, "who").into(),
            format!(
                "{} (idle {}m)",
                s(n, "reason"),
                n["idle_min"].as_i64().unwrap_or(0)
            )
            .into(),
        ]);
    }
    for a in asks {
        rows.push(vec![
            "ASK".into(),
            format!("{} {}", s(a, "id"), s(a, "project")).into(),
            s(a, "question").replace(['\t', '\n'], " ").into(),
        ]);
    }
    if rows.is_empty() {
        out.push(Line::styled("  nothing", p.dim()));
    } else {
        out.extend(
            Table {
                header: vec!["KIND", "WHO", "WHY"],
                rows,
                keep: vec![0, 1],
                flex: Some(2),
                flexmin: 20,
                flexkeep: true,
                cap: vec![(1, 30)],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }

    // MERGED, every PR, newest first
    section(&mut out, format!("MERGED ({})", merged.len()));
    if merged.is_empty() {
        out.push(Line::styled("  nothing yet", p.dim()));
    } else {
        let mut m = merged.clone();
        m.sort_by(|a, b| s(b, "merged_at").cmp(s(a, "merged_at")));
        out.extend(
            Table {
                header: vec!["TIME", "PR", "AREA", "GROUP", "BY", "TITLE"],
                rows: m
                    .iter()
                    .map(|x| {
                        vec![
                            hm(s(x, "merged_at")).into(),
                            format!("{}#{}", s(x, "repo"), x["number"]).into(),
                            or_dash(s(x, "area")).into(),
                            or_dash(s(x, "group")).into(),
                            or_dash(s(x, "by")).into(),
                            subject(s(x, "title")).to_string().into(),
                        ]
                    })
                    .collect(),
                keep: vec![1, 0, 3, 4, 2],
                flex: Some(5),
                flexmin: if w >= 100 { 40 } else { 16 },
                flexkeep: true,
                cap: vec![(1, 28), (2, 14), (3, 24), (4, 18)],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }

    // STILL OPEN: only while the day is live
    if let Some(o) = open {
        let fresh: Vec<&Value> = o.iter().filter(|x| recent(x, now)).collect();
        section(
            &mut out,
            format!("STILL OPEN ({} touched in {OPEN_DAYS}d)", fresh.len()),
        );
        if fresh.is_empty() {
            out.push(Line::styled("  none", p.dim()));
        } else {
            out.extend(
                Table {
                    header: vec!["PR", "REPO", "AGE", "CI", "BY", "TITLE"],
                    rows: fresh
                        .iter()
                        .map(|x| {
                            let age = DateTime::parse_from_rfc3339(s(x, "created_at")).map_or(
                                "-".into(),
                                |t| {
                                    let h = (now - t.timestamp()).max(0) / 3600;
                                    if h >= 48 {
                                        format!("{}d", h / 24)
                                    } else {
                                        format!("{h}h")
                                    }
                                },
                            );
                            let ci = if x["draft"].as_bool() == Some(true) {
                                "draft".to_string()
                            } else {
                                or_dash(s(x, "ci")).to_lowercase()
                            };
                            let st = match ci.as_str() {
                                "failure" | "fail" => p.bad(),
                                "success" | "pass" => p.good(),
                                "pending" => p.warn(),
                                _ => Style::new(),
                            };
                            vec![
                                format!("#{}", x["number"]).into(),
                                s(x, "repo").into(),
                                age.into(),
                                cell(ci, st),
                                or_dash(s(x, "by")).into(),
                                subject(s(x, "title")).to_string().into(),
                            ]
                        })
                        .collect(),
                    keep: vec![0, 1, 2, 3, 4],
                    flex: Some(5),
                    flexmin: 16,
                    flexkeep: true,
                    right: vec![2],
                    cap: vec![(1, 22)],
                }
                .fit(w, p.head()),
            );
        }
        if o.len() > fresh.len() {
            out.push(Line::styled(
                format!(
                    "  +{} older, untouched in {OPEN_DAYS}d",
                    o.len() - fresh.len()
                ),
                p.dim(),
            ));
        }
    }

    // SESSIONS: the bench for the day
    if let Some(b) = rec["bench"].as_object() {
        let ss = b
            .get("sessions")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        section(&mut out, format!("SESSIONS ({})", ss.len()));
        let words: Vec<&str> = b
            .get("headline")
            .and_then(Value::as_str)
            .unwrap_or("")
            .split_whitespace()
            .collect();
        out.extend(
            wrap(&words, " ", w.saturating_sub(2))
                .into_iter()
                .map(|l| Line::styled(format!("  {l}"), p.dim())),
        );
        let num = |v: &Value| match v {
            Value::Null => "-".to_string(),
            v => v.to_string(),
        };
        out.extend(
            Table {
                header: vec![
                    "SESSION", "PLAN", "PHASE", "WORK h", "WAIT h", "PRS", "REDS", "COST",
                ],
                rows: ss
                    .iter()
                    .map(|x| {
                        let t = s(x, "target");
                        let t = t.split_once('/').map_or(t, |(_, r)| r);
                        vec![
                            t.strip_suffix(":1").unwrap_or(t).to_string().into(),
                            or_dash(s(x, "plan")).into(),
                            or_dash(s(x, "phase")).into(),
                            num(&x["working_h"]).into(),
                            num(&x["waiting_h"]).into(),
                            num(&x["prs_merged"]).into(),
                            num(&x["ci_reds"]).into(),
                            money(x["cost_usd"].as_f64()).into(),
                        ]
                    })
                    .collect(),
                keep: vec![0, 2, 3, 4, 5, 7, 6, 1],
                right: vec![3, 4, 5, 6, 7],
                cap: vec![(0, 32), (1, 28)],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }

    // TIMELINE, newest first, the date dropped
    let tl: Vec<&str> = rec["timeline"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    section(&mut out, format!("TIMELINE ({})", tl.len()));
    for l in tl.iter().rev() {
        out.push(clip_line(
            Line::raw(format!("  {}", l.get(11..).unwrap_or(l))),
            w,
        ));
    }
    Page {
        lines: out,
        sections,
    }
}

/// The History tab: one row per recorded day, newest first, `sel` highlighted.
pub fn history(days: &[DayRow], sel: usize, p: Palette, w: usize) -> Vec<Line<'static>> {
    if days.is_empty() {
        return vec![Line::styled(
            "No day records yet. day-log.timer writes one every 5 minutes.",
            p.warn(),
        )];
    }
    let max = days.iter().map(|d| d.merged).max().unwrap_or(0).max(1);
    let rows = days
        .iter()
        .rev()
        .map(|d| {
            let day = chrono::NaiveDate::parse_from_str(&d.date, "%Y-%m-%d")
                .map_or(d.date.clone(), |x| x.format("%a %m-%d").to_string());
            let mut areas: Vec<(&String, &usize)> = d.areas.iter().collect();
            areas.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
            let areas: Vec<String> = areas.iter().map(|(a, n)| format!("{a} {n}")).collect();
            vec![
                Cell::from(format!("{day}{}", if d.live { " live" } else { "" })),
                d.merged.to_string().into(),
                "#".repeat((d.merged * 20).div_ceil(max)).into(),
                d.repos.to_string().into(),
                d.sessions.map_or("-".into(), |n| n.to_string()).into(),
                money(d.cost_usd).into(),
                tok(d.tokens).into(),
                areas.join(", ").into(),
            ]
        })
        .collect();
    let mut lines = Table {
        header: vec![
            "DAY", "MERGED", "", "REPOS", "SESSIONS", "COST", "TOKENS", "AREAS",
        ],
        rows,
        keep: vec![0, 1, 5, 4, 3, 6, 2],
        flex: Some(7),
        flexmin: 16,
        right: vec![1, 3, 4, 5, 6],
        ..Default::default()
    }
    .fit(w, p.head());
    if let Some(l) = lines.get_mut(sel + 1) {
        l.style = p.sel();
    }
    lines
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::boards::day_row;

    pub fn record() -> Value {
        serde_json::json!({
            "schema": 1, "date": "2026-11-03", "live": true,
            "gathered_at": "2026-11-03T12:26:03-08:00", "unreadable": [],
            "merged": [
                {"repo": ".dotfiles", "number": 722, "title": "feat(hub-tui): hub infra board",
                 "merged_at": "2026-11-03T18:07:38Z", "area": "Agent runtime", "group": "hub", "by": "hub-jobs"},
                {"repo": "unity-core-playground", "number": 1593, "title": "test(kit): WaitUntil fails",
                 "merged_at": "2026-11-03T17:04:06Z", "area": "Games", "group": "kit", "by": null}
            ],
            "open": [
                {"repo": "unity-core-playground", "number": 1649, "title": "feat(store): Steam kits",
                 "created_at": "2026-11-03T18:18:56Z", "updated_at": "2026-11-03T20:24:20Z",
                 "draft": false, "ci": "PENDING", "by": "agent-41"},
                {"repo": "x", "number": 1, "title": "old", "created_at": "2026-09-01T00:00:00Z",
                 "updated_at": "2026-09-01T00:00:00Z", "draft": false, "ci": null, "by": null}
            ],
            "waiting": {
                "main": [{"repo": "unity-core-playground", "reason": "unity-core-playground red: Shots"}],
                "needs": [{"who": "dotfiles", "reason": "1 pending ask(s)", "idle_min": 2}],
                "asks": [{"id": "ggK2ey", "project": "dotfiles", "kind": "question",
                          "question": "rename the\\nbucket?", "created": "2026-11-03T12:17:46-0800"}]
            },
            "fleet": {"sessions": 35, "buckets": {"NEEDS": 8, "WORKING": 27}, "holds": [], "unity_runs": 3},
            "bench": {"headline": "bench 24h: 108 sessions, 218 phases ticked",
                      "sessions": [{"target": "hub/dotfiles:1", "plan": "hub-plan", "phase": "6/6",
                                    "working_h": 18.3, "waiting_h": 0.6, "prs_merged": 7,
                                    "ci_reds": 0, "cost_usd": 211.22}]},
            "usage": [{"project": "dotfiles", "sessions": 15, "tokens": 865_949_077u64, "cost_usd": 418.63},
                      {"project": "TOTAL", "sessions": 65, "tokens": 2_661_687_794u64, "cost_usd": 1282.41}],
            "timeline": ["2026-11-03 11:50  hub/dotfiles:1  new: NEEDS (1 pending ask(s))",
                         "2026-11-03 12:06  lab/agent-10:1  stage NEEDS -> WORKING"]
        })
    }

    fn text(l: &[Line]) -> String {
        l.iter().map(plain).collect::<Vec<_>>().join("\n")
    }

    // 2026-11-03 20:30Z
    const NOW: i64 = 1_793_737_800;

    #[test]
    fn every_section_is_there_in_the_bash_boards_order() {
        let pg = today(Some(&record()), Palette { no_color: true }, NOW, 160);
        let t = text(&pg.lines);
        let at = |s: &str| t.find(s).unwrap_or_else(|| panic!("no {s} in\n{t}"));
        assert!(at("WAITING ON YOU (3)") < at("MERGED (2)"));
        assert!(at("MERGED (2)") < at("STILL OPEN (1 touched in 7d)"));
        assert!(at("STILL OPEN") < at("SESSIONS (1)"));
        assert!(at("SESSIONS (1)") < at("TIMELINE (2)"));
        assert_eq!(pg.sections.len(), 5);
        for i in &pg.sections {
            assert!(plain(&pg.lines[*i])
                .chars()
                .next()
                .unwrap()
                .is_ascii_uppercase());
        }
        assert!(
            t.contains("merged 2 in 2 repos  open 1 (+1 older)  65 sessions $1282.41  2.6B tokens"),
            "{t}"
        );
        assert!(t.contains("fleet WORKING 27 NEEDS 8 unity runs 3"), "{t}");
        assert!(t.contains("red: Shots") && t.contains("ggK2ey dotfiles"));
        assert!(t.contains("+1 older, untouched in 7d"));
        assert!(
            t.contains("hub infra board") && !t.contains("feat(hub-tui)"),
            "{t}"
        );
        assert!(t.contains("pending") && t.contains("$211.22"));
        // Newest merge and newest timeline line first.
        assert!(at(".dotfiles#722") < at("unity-core-playground#1593"));
        assert!(at("stage NEEDS -> WORKING") < at("new: NEEDS"));
    }

    #[test]
    fn a_past_day_has_no_open_section_and_says_it_is_past() {
        let mut r = record();
        r["live"] = false.into();
        r["open"] = Value::Null;
        let t = text(&today(Some(&r), Palette { no_color: true }, NOW, 120).lines);
        assert!(
            t.contains("past day, last gathered 2026-11-03 12:26"),
            "{t}"
        );
        assert!(!t.contains("STILL OPEN"));
    }

    #[test]
    fn no_record_says_who_writes_it() {
        let t = text(&today(None, Palette { no_color: true }, NOW, 120).lines);
        assert!(t.contains("day-log.timer"));
    }

    #[test]
    fn narrow_panes_never_overflow() {
        for w in [30, 60, 90] {
            for l in today(Some(&record()), Palette { no_color: true }, NOW, w).lines {
                assert!(
                    unicode_width::UnicodeWidthStr::width(plain(&l).as_str()) <= w,
                    "{w}: {}",
                    plain(&l)
                );
            }
        }
    }

    #[test]
    fn history_is_newest_first_with_the_selection_marked() {
        let mut old = record();
        old["date"] = "2026-11-02".into();
        old["live"] = false.into();
        old["merged"] = serde_json::json!([]);
        let rows = vec![
            day_row("2026-11-02", &old),
            day_row("2026-11-03", &record()),
        ];
        let l = history(&rows, 1, Palette { no_color: false }, 120);
        let t = text(&l);
        assert!(
            t.find("Tue 11-03 live").unwrap() < t.find("Mon 11-02").unwrap(),
            "{t}"
        );
        assert!(t.contains("Agent runtime 1, Games 1"), "{t}");
        assert_eq!(l[2].style, Palette::default().sel());
    }

    #[test]
    fn subjects_lose_only_a_conventional_prefix() {
        assert_eq!(subject("feat(hub-tui)!: a board"), "a board");
        assert_eq!(subject("fix: x"), "x");
        assert_eq!(subject("Revert \"feat: x\""), "Revert \"feat: x\"");
        assert_eq!(subject("feat(open paren"), "feat(open paren");
        assert_eq!(tok(Some(865_949_077)), "865.9M");
    }
}
