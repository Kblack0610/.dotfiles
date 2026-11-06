//! Which inbox page rows the human has marked reviewed: `<state_dir>/inbox-ack.jsonl`, one line
//! per mark or unmark, the last one for a key winning. A key is the `ts` of the ingest event the
//! row shows, so a row is told apart from another of the same words. `notes inbox ack` is its one
//! writer and the inbox page its reader. Runtime state, outside the vault, like the record.
//! Kept apart from the ingest record: a read mark is not something that happened to a line,
//! so it stays out of `notes log` and the kept score.

use crate::config::Profile;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

#[derive(Serialize, Deserialize)]
struct Mark {
    /// When it was marked, RFC 3339.
    ts: String,
    /// The ingest event's `ts`.
    key: String,
    /// False takes a mark back.
    ack: bool,
}

pub fn path(p: &Profile) -> PathBuf {
    p.state_dir.join("inbox-ack.jsonl")
}

/// The keys marked now. A line that does not parse is skipped.
pub fn acked(p: &Profile) -> HashSet<String> {
    let mut keys = HashSet::new();
    for m in fs::read_to_string(path(p))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Mark>(l).ok())
    {
        if m.ack {
            keys.insert(m.key);
        } else {
            keys.remove(&m.key);
        }
    }
    keys
}

/// `notes inbox ack <key> [--undo]`: mark the row of the ingest event at `key` reviewed, or take
/// the mark back. A key that is no event in the record is refused, so a typo writes nothing.
pub fn mark(p: &Profile, key: &str, ack: bool) -> Result<()> {
    let key = key.trim();
    let day = key.get(..10).unwrap_or_default();
    if !crate::ingest::on_day(p, day).iter().any(|e| e.ts == key) {
        bail!("no ingest event at {key:?}: a key is the ts of a row's event (`notes log --json`)");
    }
    let path = path(p);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let line = serde_json::to_string(&Mark {
        ts: chrono::Local::now().to_rfc3339(),
        key: key.into(),
        ack,
    })?;
    // One write, so two clicks at once cannot interleave within a line.
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| f.write_all(format!("{line}\n").as_bytes()))
        .with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ingest::{record, Event};

    #[test]
    fn a_mark_holds_until_taken_back_and_a_key_with_no_event_writes_nothing() {
        let root = std::env::temp_dir().join(format!("inbox-ack-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let p = crate::config::test_profile(&root.to_string_lossy());
        let ev = Event::new("filed", "demo", "demo", "loading screens");
        record(&p, &ev);

        assert!(mark(&p, "2026-01-01T00:00:00+00:00", true).is_err());
        assert!(!path(&p).exists(), "a refused key must write nothing");

        mark(&p, &ev.ts, true).unwrap();
        assert_eq!(acked(&p), HashSet::from([ev.ts.clone()]));
        mark(&p, &ev.ts, false).unwrap();
        assert!(acked(&p).is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
