//! Persistence: the append-only JSONL event log (source of truth) and the atomically
//! rewritten JSON snapshot (a rebuildable cache of live state).

use crate::event::Event;
use crate::state::Snapshot;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

/// Load the live snapshot, or a fresh default if the file is missing/unreadable/corrupt.
/// State is a cache — never fail a command because the snapshot couldn't be parsed.
pub fn load_snapshot(path: &Path) -> Snapshot {
    match fs::read_to_string(path) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
        Err(_) => Snapshot::default(),
    }
}

/// Write the snapshot atomically: serialize to `<path>.tmp`, then rename over `<path>`
/// so a reader never sees a half-written file.
pub fn save_snapshot(path: &Path, snap: &Snapshot) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(snap)?;
    fs::write(&tmp, json)?;
    fs::rename(&tmp, path)
}

/// Append one event as a JSON line to the log (create + O_APPEND).
pub fn append_event(path: &Path, ev: &Event) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let line = serde_json::to_string(ev)?;
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(line.as_bytes())?;
    f.write_all(b"\n")
}

/// Read every event from the log, skipping any line that fails to parse (forward-compat:
/// a malformed or partially-written trailing line never aborts a stats read).
pub fn read_events(path: &Path) -> Vec<Event> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<Event>(l).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::EventKind;
    use chrono::Local;

    #[test]
    fn snapshot_roundtrip_atomic() {
        let dir = std::env::temp_dir().join(format!("timebox-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("state.json");
        let mut snap = Snapshot::default();
        snap.start(Local::now(), "op", Some(1500), Some(true));
        save_snapshot(&path, &snap).unwrap();
        let back = load_snapshot(&path);
        assert!(back.stopwatches.contains_key("op"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn event_append_and_read_skips_garbage() {
        let dir = std::env::temp_dir().join(format!("timebox-ev-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("events.jsonl");
        append_event(&path, &Event::new(Local::now(), EventKind::Start, "op")).unwrap();
        // a corrupt trailing line must not break the read
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{not json}\n").unwrap();
        let evs = read_events(&path);
        assert_eq!(evs.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
