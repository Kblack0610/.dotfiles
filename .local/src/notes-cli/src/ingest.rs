//! The ingest record: one JSONL event per line an intake step moved, filed or left, at
//! `<state_dir>/ingest.jsonl`. It is the one source for "what was ingested and where": the
//! inbox status page reads it, and the triager's eval scores against it. Runtime state, so it
//! lives outside the vault, as the rule on telemetry in `notes-system` says.

use crate::config::Profile;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::PathBuf;

/// One intake step on one line.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Event {
    /// RFC 3339, local time.
    pub ts: String,
    /// `moved` (outbox or Focus -> an inbox), `filed`, `dup`, `left` (waits for the human) or
    /// `refused` (a write the CLI turned down).
    pub action: String,
    /// Where the line was: `outbox`, `focus`, or the project whose inbox held it.
    pub from: String,
    /// The project it went to; empty when it stayed.
    #[serde(default)]
    pub to: String,
    /// `human` or `agent` for a filing; empty otherwise.
    #[serde(default)]
    pub lane: String,
    /// The line's words.
    pub text: String,
    /// The row id it was filed as, or the open row it joined.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Why it stayed, for `left` and `refused`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// For `filed`: the first row's words as filed ([`row_words`]), which [`kept`] compares
    /// with the row's words now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
}

impl Event {
    pub fn new(action: &str, from: &str, to: &str, text: &str) -> Self {
        Event {
            ts: chrono::Local::now().to_rfc3339(),
            action: action.into(),
            from: from.into(),
            to: to.into(),
            text: text.trim().into(),
            ..Default::default()
        }
    }
}

pub fn path(p: &Profile) -> PathBuf {
    p.state_dir.join("ingest.jsonl")
}

/// Past this size the record is cut to its last [`KEEP_DAYS`], so the page's read stays cheap.
const MAX_BYTES: u64 = 512 * 1024;
const KEEP_DAYS: i64 = 30;

/// Append `ev`. Best effort, like the inbox flag: a record that cannot be written must not
/// fail the move it describes, so the error goes to stderr and the write stands.
pub fn record(p: &Profile, ev: &Event) {
    let path = path(p);
    let res = (|| -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        let line = serde_json::to_string(ev).map_err(std::io::Error::other)?;
        writeln!(f, "{line}")?;
        if f.metadata()?.len() > MAX_BYTES {
            prune(&path)?;
        }
        Ok(())
    })();
    if let Err(e) = res {
        eprintln!("ingest record not written ({}): {e}", path.display());
    }
}

/// Keep the events of the last [`KEEP_DAYS`]. RFC 3339 stamps of one zone sort as text.
fn prune(path: &std::path::Path) -> std::io::Result<()> {
    let cut = (chrono::Local::now() - chrono::Duration::days(KEEP_DAYS)).to_rfc3339();
    let kept: String = fs::read_to_string(path)?
        .lines()
        .filter(|l| l.get(7..7 + cut.len()).is_some_and(|ts| ts >= &cut[..]))
        .map(|l| format!("{l}\n"))
        .collect();
    crate::md::write_atomic(path, &kept).map_err(std::io::Error::other)
}

/// Every event on `day` (`YYYY-MM-DD`), oldest first. A line that does not parse is skipped.
/// `ts` is serialized first, so a line from another day is passed over without parsing it:
/// `notes today` reads this on every shell start.
pub fn on_day(p: &Profile, day: &str) -> Vec<Event> {
    let head = format!("{{\"ts\":\"{day}");
    fs::read_to_string(path(p))
        .unwrap_or_default()
        .lines()
        .filter(|l| l.starts_with(&head))
        .filter_map(|l| serde_json::from_str::<Event>(l).ok())
        .collect()
}

/// Every event of the last `days` days, today included, oldest first.
pub fn since(p: &Profile, days: i64) -> Vec<Event> {
    let cut = (chrono::Local::now() - chrono::Duration::days(days - 1))
        .format("%Y-%m-%d")
        .to_string();
    fs::read_to_string(path(p))
        .unwrap_or_default()
        .lines()
        .filter(|l| l.get(7..17).is_some_and(|d| d >= &cut[..]))
        .filter_map(|l| serde_json::from_str::<Event>(l).ok())
        .collect()
}

/// A row's words as [`kept`] compares them: its text without the hashtags, so the planner's
/// tag edits (`#plan` off, a size) leave a filing kept, and a new type, area or title does not.
pub fn row_words(line: &str) -> String {
    let text = crate::md::task_text(line);
    let words: Vec<&str> = text
        .split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .collect();
    words.join(" ")
}

/// Where a row is now: its project, its lane, and its line.
pub struct Found {
    pub project: String,
    pub lane: &'static str,
    pub line: String,
}

/// How many of `events`' filings still stand as filed, of how many: a filing is kept when its
/// row is in the project and lane it was filed to, not dropped or closed as a dup, with its
/// words unchanged. Open, in progress and done all count. Counted, never judged by a model:
/// the human's edits are the label.
pub fn kept(events: &[Event], rows: &std::collections::HashMap<String, Found>) -> (usize, usize) {
    let filed: Vec<(&Event, &str)> = events
        .iter()
        .filter(|e| e.action == "filed")
        .filter_map(|e| Some((e, e.id.as_deref()?)))
        .collect();
    let kept = filed
        .iter()
        .filter(|(e, id)| {
            rows.get(*id).is_some_and(|f| {
                f.project == e.to
                    && f.lane == e.lane
                    && crate::md::marker_token(&f.line, "dropped:").is_none()
                    && crate::md::marker_token(&f.line, "dup:").is_none()
                    && e.row.as_deref().is_none_or(|w| row_words(&f.line) == w)
            })
        })
        .count();
    (kept, filed.len())
}

/// The rows with one of `ids`, from every `.md` under each project dir (both lanes and the
/// `versions/` archive, so a row closed and released still counts).
pub fn find_rows(
    dirs: &[(String, PathBuf)],
    ids: &std::collections::HashSet<&str>,
) -> std::collections::HashMap<String, Found> {
    let mut out = std::collections::HashMap::new();
    if ids.is_empty() {
        return out;
    }
    for (project, dir) in dirs {
        let agent = crate::agent_sheet::Lane::Agent.dir(dir);
        let mut stack = vec![dir.clone()];
        while let Some(d) = stack.pop() {
            let Ok(entries) = fs::read_dir(&d) else {
                continue;
            };
            for e in entries.flatten() {
                let path = e.path();
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    stack.push(path);
                    continue;
                }
                if path.extension().is_none_or(|x| x != "md") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                let lane = if path.starts_with(&agent) {
                    "agent"
                } else {
                    "human"
                };
                for line in text.lines().filter(|l| l.contains("id:")) {
                    let Some(id) = crate::md::row_id(line) else {
                        continue;
                    };
                    if ids.contains(id.as_str()) {
                        out.entry(id).or_insert_with(|| Found {
                            project: project.clone(),
                            lane,
                            line: line.to_string(),
                        });
                    }
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filing_is_kept_only_where_it_was_filed_with_its_words() {
        let dir = std::env::temp_dir().join(format!("ingest-kept-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let proj = dir.join("demo");
        fs::create_dir_all(proj.join("agent")).unwrap();
        fs::create_dir_all(proj.join("versions")).unwrap();
        fs::write(
            proj.join("README.md"),
            "## Tasks\n\
             - [ ] fix(ui): the menu flickers #low <!-- id:dm-1 filed:2026-11-05 -->\n\
             - [ ] feat(kit): a brand kit #size/l #high <!-- id:dm-2 filed:2026-11-05 -->\n\
             - [x] fix(ui): a stale thing <!-- id:dm-3 dropped: stale -->\n\
             - [x] fix(ui): the same thing <!-- id:dm-4 dup:dm-1 -->\n\
             - [ ] fix(ui): a new title <!-- id:dm-5 -->\n\
             - [ ] fix(ui): went human <!-- id:dm-6 -->\n",
        )
        .unwrap();
        fs::write(
            proj.join("versions").join("v0.1.0.md"),
            "- [x] fix(ui): shipped <!-- id:dm-7 pr:12 -->\n",
        )
        .unwrap();
        fs::write(
            proj.join("agent").join("README.md"),
            "## Tasks\n- [ ] ci(gate): a gate <!-- id:dm-8 -->\n",
        )
        .unwrap();
        let filing = |id: &str, lane: &str, row: Option<&str>| {
            let mut e = Event::new("filed", "demo", "demo", "words");
            e.lane = lane.into();
            e.id = Some(id.into());
            e.row = row.map(str::to_string);
            e
        };
        let mut moved = filing("dm-1", "human", None);
        moved.to = "other".into();
        let events = vec![
            filing("dm-1", "human", Some("fix(ui): the menu flickers")),
            // The planner's tag edits leave it kept.
            filing("dm-2", "human", Some("feat(kit): a brand kit")),
            filing("dm-3", "human", None),
            filing("dm-4", "human", None),
            filing("dm-5", "human", Some("fix(ui): the old title")),
            filing("dm-6", "agent", None),
            filing("dm-7", "human", Some("fix(ui): shipped")),
            filing("dm-8", "agent", Some("ci(gate): a gate")),
            filing("dm-9", "human", None),
            moved,
            Event::new("left", "demo", "", "a thought"),
        ];
        let ids: std::collections::HashSet<&str> =
            events.iter().filter_map(|e| e.id.as_deref()).collect();
        let rows = find_rows(&[("demo".into(), proj)], &ids);
        assert_eq!(rows["dm-8"].lane, "agent");
        assert_eq!(rows["dm-7"].lane, "human");
        // Kept: dm-1, dm-2, dm-7 (done and released), dm-8. Not: dropped dm-3, dup dm-4,
        // retitled dm-5, other lane dm-6, gone dm-9, other project.
        assert_eq!(kept(&events, &rows), (4, 10));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn events_round_trip_and_read_back_by_day() {
        let dir = std::env::temp_dir().join(format!("ingest-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = crate::config::test_profile(dir.to_str().unwrap());
        let mut ev = Event::new("filed", "outbox", "dodginballs", " the gun sound is late ");
        ev.lane = "human".into();
        ev.id = Some("db-12".into());
        record(&p, &ev);
        let mut old = Event::new("left", "nc", "", "a thought");
        old.ts = "2026-01-01T09:00:00-08:00".into();
        record(&p, &old);
        let got = on_day(&p, &ev.ts[..10]);
        assert_eq!(
            got,
            vec![Event {
                text: "the gun sound is late".into(),
                ..ev
            }]
        );
        assert_eq!(on_day(&p, "2026-01-01").len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
