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

#[cfg(test)]
mod tests {
    use super::*;

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
