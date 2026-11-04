//! The fleet and day-log boards' files. Their own tools write them (`fleet-sessions tick`, run
//! every minute by fleet-state.timer, and `day-log snapshot`, by day-log.timer); this module
//! only parses them, for agent-web's Watch and Log tabs and the hub TUI's Sessions, Today and
//! History tabs, so the surfaces can never disagree about what happened.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

/// Transitions sent to the Watch tab: about a day of a busy fleet, sync lines included.
pub const WATCH_LOG_LINES: usize = 1500;

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn env(k: &str) -> Option<PathBuf> {
    std::env::var_os(k)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// `fleet-sessions`' state document, by the same variables it resolves.
pub fn fleet_state() -> PathBuf {
    env("FLEET_STATE_FILE").unwrap_or_else(|| {
        env("XDG_STATE_HOME")
            .unwrap_or_else(|| home().join(".local/state"))
            .join("fleet/state.json")
    })
}

/// Where `fleet-sessions` keeps watch.log (`FLEET_SHEPHERD_DIR`).
pub fn shepherd_dir() -> PathBuf {
    env("FLEET_SHEPHERD_DIR").unwrap_or_else(|| home().join(".agent/shepherd"))
}

/// `fleet-dispatch`'s dir: `verdicts.jsonl` and `log.md` (its `FLEET_DISPATCH_DIR`).
pub fn dispatch_dir() -> PathBuf {
    env("FLEET_DISPATCH_DIR").unwrap_or_else(|| home().join(".agent/dispatch"))
}

/// `day-log`'s records, one `<YYYY-MM-DD>.json` per local day (its `DAYLOG_DIR`).
pub fn daylog_dir() -> PathBuf {
    std::env::var_os("DAYLOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".agent/daylog"))
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

/// A session's plan progress, as `fleet-sessions` read its plan's `## Phases` checklist.
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Phases {
    pub done: u64,
    pub total: u64,
    /// The first unchecked phase.
    pub next: Option<String>,
}

/// Each session's plan progress by its tmux target, from a `state.json` document. A session
/// whose plan has no checklist has no entry.
pub fn phases(state: &Value) -> std::collections::HashMap<String, Phases> {
    state["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let total = r["phases_total"].as_u64().filter(|t| *t > 0)?;
            Some((
                r["target"].as_str()?.to_string(),
                Phases {
                    done: r["phases_done"].as_u64().unwrap_or(0),
                    total,
                    next: r["next_phase"].as_str().map(String::from),
                },
            ))
        })
        .collect()
}

/// One rundown or chat answer the shepherd kept (`fleet-shepherd log --rundown`).
#[derive(Serialize, Debug, PartialEq)]
pub struct Rundown {
    /// The file name, `<YYYY-MM-DD>T<HHMM>Z[-N].md`.
    pub file: String,
    pub title: String,
    /// `YYYY-MM-DD HH:MM UTC`, as written.
    pub stamp: String,
    pub body: String,
}

/// Newest-first sort key for a rundown file: its minute, then the `-N` a second record in the
/// same minute gets (the first has none, so it counts as 1).
fn rundown_key(file: &str) -> (String, u32) {
    let stem = file.strip_suffix(".md").unwrap_or(file);
    match stem.rsplit_once('-') {
        Some((base, n)) if base.ends_with('Z') => (base.to_string(), n.parse().unwrap_or(1)),
        _ => (stem.to_string(), 1),
    }
}

/// The file as `log_rundown` writes it: `# <title>`, a blank line, the stamp, a blank line, the
/// body. A file in any other shape keeps its whole text as the body.
pub fn parse_rundown(file: &str, text: &str) -> Rundown {
    let mut parts = text.splitn(3, "\n\n");
    let (head, stamp, body) = (parts.next(), parts.next(), parts.next());
    match (head.and_then(|h| h.strip_prefix("# ")), stamp, body) {
        (Some(title), Some(stamp), Some(body))
            if !title.contains('\n') && stamp.ends_with("UTC") =>
        {
            Rundown {
                file: file.into(),
                title: title.into(),
                stamp: stamp.into(),
                body: body.trim_end().into(),
            }
        }
        _ => Rundown {
            file: file.into(),
            title: file.into(),
            stamp: String::new(),
            body: text.trim_end().into(),
        },
    }
}

/// The newest `limit` rundowns in `dir`, newest first.
pub fn rundowns(dir: &Path, limit: usize) -> Vec<Rundown> {
    let mut files: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n.ends_with(".md") && !n.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    files.sort_by_key(|f| std::cmp::Reverse(rundown_key(f)));
    files
        .into_iter()
        .take(limit)
        .filter_map(|f| {
            let text = std::fs::read_to_string(dir.join(&f)).ok()?;
            Some(parse_rundown(&f, &text))
        })
        .collect()
}

/// One due line the last `fleet-shepherd check` handed to a pass (its `.due`, one TSV row each:
/// key, role, first-seen epoch, line).
#[derive(Serialize, Debug, PartialEq)]
pub struct DueLine {
    pub key: String,
    /// The role skill the line routes to (`fleet-shepherd line_role`); empty on a row an older
    /// check wrote, until the next check rewrites it.
    pub role: String,
    /// When a check first printed this line; 0 when the row does not say.
    pub first_seen: u64,
    /// The line, without its `unhandled: ` prefix.
    pub line: String,
    /// The previous pass was given this line and neither moved nor skipped it.
    pub unhandled: bool,
}

/// A due line a pass left on purpose (`fleet-shepherd skip`, its `.skipped`: key, why, epoch).
#[derive(Serialize, Debug, PartialEq)]
pub struct Skip {
    pub key: String,
    pub why: String,
    pub at: u64,
}

/// What Binks owes and what it chose not to do, from `fleet-shepherd`'s ledger.
#[derive(Serialize, Debug, PartialEq, Default)]
pub struct Due {
    pub due: Vec<DueLine>,
    pub skipped: Vec<Skip>,
    /// Who holds the pass lease (`.lease`: holder, epoch): `runner`, or `interactive` for a
    /// loop the human drives.
    pub lease_holder: Option<String>,
    /// When the last pass took the lease.
    pub lease_at: Option<u64>,
}

fn tsv_rows(path: &Path) -> Vec<Vec<String>> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.split('\t').map(String::from).collect())
        .collect()
}

/// The ledger in `dir`. A missing file reads as empty.
pub fn due(dir: &Path) -> Due {
    let due = tsv_rows(&dir.join(".due"))
        .into_iter()
        .map(|f| {
            let key = f[0].clone();
            let line = f.get(3).cloned().unwrap_or_else(|| key.clone());
            let (unhandled, line) = match line.strip_prefix("unhandled: ") {
                Some(l) => (true, l.to_string()),
                None => (false, line),
            };
            DueLine {
                key,
                role: f.get(1).cloned().unwrap_or_default(),
                first_seen: f.get(2).and_then(|s| s.parse().ok()).unwrap_or(0),
                line,
                unhandled,
            }
        })
        .collect();
    let skipped = tsv_rows(&dir.join(".skipped"))
        .into_iter()
        .map(|f| Skip {
            key: f[0].clone(),
            why: f.get(1).cloned().unwrap_or_default(),
            at: f.get(2).and_then(|s| s.parse().ok()).unwrap_or(0),
        })
        .collect();
    let lease = std::fs::read_to_string(dir.join(".lease")).unwrap_or_default();
    let mut lease = lease.split_whitespace();
    Due {
        due,
        skipped,
        lease_holder: lease.next().map(String::from),
        lease_at: lease.next().and_then(|s| s.parse().ok()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_are_keyed_by_target_and_skip_a_plan_with_no_checklist() {
        let state = serde_json::json!({"sessions": [
            {"target": "lab/a:1", "phases_done": 3, "phases_total": 6, "next_phase": "4: weight tags"},
            {"target": "lab/b:1", "phases_done": 2, "phases_total": 2, "next_phase": null},
            {"target": "lab/c:1", "phases_done": null, "phases_total": null},
        ]});
        let p = phases(&state);
        assert_eq!(p.len(), 2);
        assert_eq!(
            p["lab/a:1"],
            Phases {
                done: 3,
                total: 6,
                next: Some("4: weight tags".into())
            }
        );
        assert_eq!(p["lab/b:1"].next, None);
        assert!(phases(&Value::Null).is_empty());
    }

    #[test]
    fn rundowns_come_newest_first_with_same_minute_records_in_order() {
        let dir = std::env::temp_dir().join(format!("hub-core-rundowns-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let write = |name: &str, title: &str| {
            let text = format!("# {title}\n\n2026-11-03 12:01 UTC\n\nline one\n\nline two\n");
            std::fs::write(dir.join(name), text).unwrap();
        };
        write("2026-11-02T2359Z.md", "yesterday");
        write("2026-11-03T1201Z.md", "first");
        write("2026-11-03T1201Z-2.md", "second");
        write("2026-11-03T1201Z-10.md", "tenth");
        std::fs::write(dir.join("2026-11-03T1300Z.md.tmp"), "half written").unwrap();
        let got = rundowns(&dir, 10);
        let titles: Vec<&str> = got.iter().map(|r| r.title.as_str()).collect();
        assert_eq!(titles, vec!["tenth", "second", "first", "yesterday"]);
        assert_eq!(got[0].stamp, "2026-11-03 12:01 UTC");
        assert_eq!(got[0].body, "line one\n\nline two");
        assert_eq!(rundowns(&dir, 1).len(), 1);
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(rundowns(&dir, 5).is_empty(), "a missing dir is no rundowns");
    }

    #[test]
    fn a_rundown_in_another_shape_keeps_its_text() {
        let r = parse_rundown("x.md", "just some notes\nwith no heading\n");
        assert_eq!(r.title, "x.md");
        assert_eq!(r.stamp, "");
        assert_eq!(r.body, "just some notes\nwith no heading");
    }

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

    #[test]
    fn due_reads_the_shepherd_ledger_and_an_empty_dir_reads_as_nothing() {
        let dir = std::env::temp_dir().join(format!("hub-core-due-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(due(&dir), Due::default());
        std::fs::write(
            dir.join(".due"),
            "nudge STALLED: a:1\tshepherd\t1000\tunhandled: nudge STALLED: a:1 idle 30m\n\
             pace: HOLD\tfleet-pace\t2000\tpace: HOLD\n\
             legacy key only\n",
        )
        .unwrap();
        std::fs::write(dir.join(".skipped"), "pace: HOLD\tkept on purpose\t3000\n").unwrap();
        std::fs::write(dir.join(".lease"), "runner 4000\n").unwrap();
        let d = due(&dir);
        assert_eq!(d.due.len(), 3);
        assert_eq!(
            d.due[0],
            DueLine {
                key: "nudge STALLED: a:1".into(),
                role: "shepherd".into(),
                first_seen: 1000,
                line: "nudge STALLED: a:1 idle 30m".into(),
                unhandled: true,
            }
        );
        assert!(!d.due[1].unhandled);
        assert_eq!(
            (
                d.due[2].line.as_str(),
                d.due[2].role.as_str(),
                d.due[2].first_seen
            ),
            ("legacy key only", "", 0)
        );
        assert_eq!(
            d.skipped,
            vec![Skip {
                key: "pace: HOLD".into(),
                why: "kept on purpose".into(),
                at: 3000
            }]
        );
        assert_eq!(
            (d.lease_holder.as_deref(), d.lease_at),
            (Some("runner"), Some(4000))
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
