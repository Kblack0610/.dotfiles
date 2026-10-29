//! The hub boards, read for the browser. Each board's own tool writes the files read here
//! (`fleet-sessions --write`, its watch ticks, `day-log`); this module only parses them, so
//! the web tabs and the tmux boards can never disagree about what happened.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use agent_panel::session;

/// Transitions sent to the Watch tab: about a day of a busy fleet, sync lines included.
pub const WATCH_LOG_LINES: usize = 1500;

pub fn fleet_state() -> PathBuf {
    session::home().join(".local/state/fleet/state.json")
}

pub fn shepherd_dir() -> PathBuf {
    session::home().join(".agent/shepherd")
}

/// `day-log`'s records, one `<YYYY-MM-DD>.json` per local day (its `DAYLOG_DIR`).
pub fn daylog_dir() -> PathBuf {
    std::env::var_os("DAYLOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| session::home().join(".agent/daylog"))
}

/// A day name the API accepts: exactly `YYYY-MM-DD`, so it can never name another file.
pub fn is_day(s: &str) -> bool {
    s.len() == 10
        && s.char_indices().all(|(i, c)| {
            if i == 4 || i == 7 {
                c == '-'
            } else {
                c.is_ascii_digit()
            }
        })
}

/// Every day that has a record, oldest first.
pub fn days(dir: &Path) -> Vec<String> {
    let mut d: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter_map(|e| {
                    e.file_name()
                        .to_str()?
                        .strip_suffix(".json")
                        .map(String::from)
                })
                .filter(|n| is_day(n))
                .collect()
        })
        .unwrap_or_default();
    d.sort();
    d
}

/// One day of the Log tab's history charts, from that day's record.
#[derive(Serialize, Debug, PartialEq)]
pub struct DayRow {
    pub date: String,
    pub live: bool,
    pub merged: usize,
    /// Merged PRs per `area`, the coarse grouping `~/.config/day-log/groups` assigns.
    pub areas: std::collections::BTreeMap<String, usize>,
    pub repos: usize,
    /// The `TOTAL` row of `usage`, when the day has one.
    pub sessions: Option<u64>,
    pub cost_usd: Option<f64>,
    pub tokens: Option<u64>,
}

pub fn day_row(date: &str, rec: &Value) -> DayRow {
    let merged = rec["merged"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let mut areas = std::collections::BTreeMap::new();
    let mut repos = std::collections::BTreeSet::new();
    for pr in merged {
        *areas
            .entry(pr["area"].as_str().unwrap_or("other").to_string())
            .or_insert(0) += 1;
        if let Some(r) = pr["repo"].as_str() {
            repos.insert(r);
        }
    }
    let total = rec["usage"]
        .as_array()
        .and_then(|u| u.iter().find(|r| r["project"] == "TOTAL"));
    DayRow {
        date: date.into(),
        live: rec["live"].as_bool().unwrap_or(false),
        merged: merged.len(),
        areas,
        repos: repos.len(),
        sessions: total.and_then(|t| t["sessions"].as_u64()),
        cost_usd: total.and_then(|t| t["cost_usd"].as_f64()),
        tokens: total.and_then(|t| t["tokens"].as_u64()),
    }
}

/// History charts span at most this many days; a record is about 130 KB.
pub const HISTORY_MAX_DAYS: usize = 120;

fn read_day(dir: &Path, day: &str) -> Option<Value> {
    let raw = std::fs::read_to_string(dir.join(format!("{day}.json"))).ok()?;
    serde_json::from_str(&raw).ok()
}

/// A day's record as `day-log` wrote it, or the latest day's when `day` is None.
pub fn record(dir: &Path, day: Option<&str>) -> Option<Value> {
    let day = match day {
        Some(d) => d.to_string(),
        None => days(dir).pop()?,
    };
    read_day(dir, &day)
}

/// One row for each of the last `n` recorded days, oldest first. A record that does not parse
/// is skipped, not fatal: `day-log` replaces today's file by a rename, so a half-written one is
/// never read.
pub fn history(dir: &Path, n: usize) -> Vec<DayRow> {
    let all = days(dir);
    let skip = all.len().saturating_sub(n.min(HISTORY_MAX_DAYS));
    all[skip..]
        .iter()
        .filter_map(|d| Some(day_row(d, &read_day(dir, d)?)))
        .collect()
}

/// One line of `~/.agent/shepherd/watch.log`, written by `fleet-sessions` `transitions()`:
/// `YYYY-MM-DD HH:MM  <target>  new: <BUCKET> (<why>)`, `... <target>  gone`, or
/// `... <target>  <field> <old> -> <new>[, <field> <old> -> <new>...][ (<why>)]`, where the
/// reason is present only when the stage changed. Times are the host's local time.
#[derive(Serialize, Debug, PartialEq)]
pub struct Transition {
    pub ts: String,
    pub target: String,
    /// `new`, `gone` or `change`.
    pub kind: &'static str,
    /// The bucket left, for a stage change.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// The bucket entered, for `new` and a stage change.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    /// Every field the line changed (`sync`, `ci`, `stage`, ...), for filtering.
    pub fields: Vec<String>,
    pub text: String,
}

pub fn parse_transition(line: &str) -> Option<Transition> {
    let mut parts = line.splitn(3, "  ");
    let ts = parts.next()?.trim();
    let target = parts.next()?.trim();
    let text = parts.next()?.trim();
    if ts.len() != 16 || target.is_empty() || text.is_empty() {
        return None;
    }
    let mut t = Transition {
        ts: ts.into(),
        target: target.into(),
        kind: "change",
        from: None,
        to: None,
        fields: vec![],
        text: text.into(),
    };
    if text == "gone" {
        t.kind = "gone";
    } else if let Some(rest) = text.strip_prefix("new: ") {
        t.kind = "new";
        t.to = rest.split_whitespace().next().map(String::from);
    } else {
        // The reason is the stage's, and comes last; the cells before it never hold " (".
        let cells = text.split(" (").next().unwrap_or(text);
        for cell in cells.split(", ") {
            let Some((field, change)) = cell.split_once(' ') else {
                continue;
            };
            t.fields.push(field.into());
            if field == "stage" {
                if let Some((a, b)) = change.split_once(" -> ") {
                    t.from = Some(a.into());
                    t.to = Some(b.into());
                }
            }
        }
    }
    Some(t)
}

#[derive(Serialize)]
pub struct Watch {
    /// `state.json` exactly as `fleet-sessions --write` left it, or null when it is missing.
    pub state: Value,
    /// Oldest first.
    pub transitions: Vec<Transition>,
}

pub fn watch(state: &Path, log: &Path) -> Watch {
    let state = std::fs::read_to_string(state)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
    let log = std::fs::read_to_string(log).unwrap_or_default();
    let lines: Vec<&str> = log.lines().collect();
    let skip = lines.len().saturating_sub(WATCH_LOG_LINES);
    Watch {
        state,
        transitions: lines[skip..]
            .iter()
            .filter_map(|l| parse_transition(l))
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_stage_change() {
        let t = parse_transition(
            "2026-10-29 11:19  unity-core-playground-agent-26:1  stage WORKING -> STALLED (PR #1180 green, not merged)",
        )
        .unwrap();
        assert_eq!(t.ts, "2026-10-29 11:19");
        assert_eq!(t.target, "unity-core-playground-agent-26:1");
        assert_eq!(t.kind, "change");
        assert_eq!(t.from.as_deref(), Some("WORKING"));
        assert_eq!(t.to.as_deref(), Some("STALLED"));
        assert_eq!(t.fields, vec!["stage"]);
    }

    #[test]
    fn parses_several_cells_on_one_line() {
        let t = parse_transition(
            "2026-10-29 11:22  dotfiles:2  sync 8 behind -> 12 behind, ci pending -> pass",
        )
        .unwrap();
        assert_eq!(t.fields, vec!["sync", "ci"]);
        assert_eq!(t.to, None);
    }

    #[test]
    fn parses_new_and_gone() {
        let n = parse_transition(
            "2026-10-29 11:17  dotfiles:2  new: UNCLEAR (clean, nothing on the branch, no plan file)",
        )
        .unwrap();
        assert_eq!((n.kind, n.to.as_deref()), ("new", Some("UNCLEAR")));
        let g = parse_transition("2026-10-29 10:52  dotfiles:5  gone").unwrap();
        assert_eq!(g.kind, "gone");
    }

    #[test]
    fn skips_lines_that_are_not_transitions() {
        assert_eq!(parse_transition(""), None);
        assert_eq!(parse_transition("2026-10-29 11:22  dotfiles:2"), None);
        assert_eq!(parse_transition("garbage  x  y"), None);
    }

    #[test]
    fn day_names_are_strict() {
        assert!(is_day("2026-10-29"));
        assert!(!is_day("2026-10-2"));
        assert!(!is_day("../x/10-29"));
        assert!(!is_day("2026-10-29.json"));
        assert!(!is_day("2026/10/29"));
    }

    #[test]
    fn day_row_counts_areas_repos_and_spend() {
        let rec: Value = serde_json::json!({
            "live": true,
            "merged": [
                {"repo": "a", "area": "Games"},
                {"repo": "a", "area": "Games"},
                {"repo": "b", "area": "Fleet tooling"},
                {"repo": "b"}
            ],
            "usage": [
                {"project": "a", "sessions": 3, "tokens": 10, "cost_usd": 1.5},
                {"project": "TOTAL", "sessions": 5, "tokens": 20, "cost_usd": 2.25}
            ]
        });
        let r = day_row("2026-10-29", &rec);
        assert_eq!(r.merged, 4);
        assert_eq!(r.repos, 2);
        assert_eq!(r.areas["Games"], 2);
        assert_eq!(r.areas["other"], 1);
        assert_eq!(
            (r.sessions, r.cost_usd, r.tokens),
            (Some(5), Some(2.25), Some(20))
        );
        assert!(r.live);
    }

    #[test]
    fn day_row_tolerates_an_old_or_partial_record() {
        let r = day_row("2026-10-14", &serde_json::json!({"schema": 1}));
        assert_eq!((r.merged, r.repos, r.cost_usd, r.live), (0, 0, None, false));
    }

    #[test]
    fn history_reads_days_in_order_and_skips_bad_files() {
        let dir = std::env::temp_dir().join(format!("agent-web-daylog-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("2026-10-29.json"), r#"{"merged":[{"repo":"a"}]}"#).unwrap();
        std::fs::write(dir.join("2026-10-28.json"), r#"{"merged":[]}"#).unwrap();
        std::fs::write(dir.join("2026-10-27.json"), "{not json").unwrap();
        std::fs::write(dir.join(".lock"), "").unwrap();
        std::fs::write(dir.join("notes.json"), "{}").unwrap();
        let h = history(&dir, 30);
        let last = history(&dir, 1);
        let latest = record(&dir, None);
        let missing = record(&dir, Some("2026-01-01"));
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(
            h.iter().map(|r| r.date.as_str()).collect::<Vec<_>>(),
            ["2026-10-28", "2026-10-29"]
        );
        assert_eq!(h[1].merged, 1);
        assert_eq!(last.len(), 1);
        assert_eq!(latest.unwrap()["merged"][0]["repo"], "a");
        assert_eq!(missing, None);
    }

    #[test]
    fn watch_survives_missing_files() {
        let w = watch(
            Path::new("/nonexistent/state.json"),
            Path::new("/nonexistent/log"),
        );
        assert_eq!(w.state, Value::Null);
        assert!(w.transitions.is_empty());
    }
}
