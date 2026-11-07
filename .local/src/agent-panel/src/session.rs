//! Read `~/.claude/sessions/<pid>.json` — the canonical pid → sessionId + cwd
//! + status mapping Claude Code maintains — plus status glyph and JSONL path.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Session {
    pub pid: u32,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub status: String,
    /// Epoch milliseconds the Claude process started, None on files that predate it.
    #[serde(rename = "startedAt", default)]
    pub started_at: Option<u64>,
}

/// Directory holding the per-pid session files.
fn sessions_dir() -> PathBuf {
    home().join(".claude").join("sessions")
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Load every `~/.claude/sessions/<pid>.json` into a pid-keyed map, and the pids (from the
/// file names) whose file would not read or parse. A stale file must not break the panel, so
/// the caller decides: one whose pid is live may be a file Claude was rewriting, and the read
/// that skipped it is missing that session (ar-916).
pub fn load_all() -> (HashMap<u32, Session>, Vec<u32>) {
    load_dir(&sessions_dir())
}

/// A file that will not parse is read once more before it counts: Claude rewrites it on each
/// status change, so a read that met the write half done gets the whole file the next time.
fn load_dir(dir: &Path) -> (HashMap<u32, Session>, Vec<u32>) {
    let read = |p: &Path| fs::read_to_string(p).ok().and_then(|t| serde_json::from_str::<Session>(&t).ok());
    let (mut out, mut unreadable) = (HashMap::new(), Vec::new());
    let Ok(rd) = fs::read_dir(dir) else {
        return (out, unreadable);
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        match read(&path).or_else(|| read(&path)) {
            Some(sess) => {
                out.insert(sess.pid, sess);
            }
            None => unreadable.extend(path.file_stem().and_then(|s| s.to_str()?.parse::<u32>().ok())),
        }
    }
    (out, unreadable)
}

/// Status glyph: `waiting`→`!` (needs input), `busy`/`shell`→`~`, anything
/// else (`idle`)→`✓`. Claude writes `shell` when it is idle at the prompt but a
/// background Bash task is still running, so it is still working, not done.
pub fn glyph(status: &str) -> char {
    match status {
        "waiting" => '!',
        "busy" | "shell" => '~',
        _ => '✓',
    }
}

/// Compute the transcript JSONL path from sessionId + cwd. Claude encodes
/// `/`, `.`, and `_` all as `-` in the project directory name.
pub fn jsonl_path(session_id: &str, cwd: &str) -> PathBuf {
    let enc: String = cwd
        .chars()
        .map(|c| if matches!(c, '/' | '.' | '_') { '-' } else { c })
        .collect();
    home()
        .join(".claude")
        .join("projects")
        .join(enc)
        .join(format!("{session_id}.jsonl"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unreadable_file_is_named_by_its_pid() {
        let dir = std::env::temp_dir().join(format!("agent-panel-sessions-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("10.json"), r#"{"pid":10,"sessionId":"s10","cwd":"/w"}"#).unwrap();
        fs::write(dir.join("11.json"), r#"{"pid":11,"sess"#).unwrap(); // met mid-write
        fs::write(dir.join("notes.json"), "{").unwrap(); // no pid in the name: not a session
        let (sessions, unreadable) = load_dir(&dir);
        assert_eq!(sessions.keys().copied().collect::<Vec<_>>(), vec![10]);
        assert_eq!(unreadable, vec![11]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn glyphs() {
        assert_eq!(glyph("waiting"), '!');
        assert_eq!(glyph("busy"), '~');
        assert_eq!(glyph("shell"), '~');
        assert_eq!(glyph("idle"), '✓');
        assert_eq!(glyph("anything"), '✓');
    }

    #[test]
    fn encodes_jsonl_path() {
        let p = jsonl_path("abc-123", "/home/k/dev/bnb/platform-agent-2");
        assert!(p.to_string_lossy().ends_with(
            ".claude/projects/-home-k-dev-bnb-platform-agent-2/abc-123.jsonl"
        ));
    }

    #[test]
    fn parses_session_json() {
        let s: Session = serde_json::from_str(
            r#"{"pid":42,"sessionId":"sid","cwd":"/tmp","status":"busy","extra":1}"#,
        )
        .unwrap();
        assert_eq!(s.pid, 42);
        assert_eq!(s.session_id, "sid");
        assert_eq!(s.status, "busy");
        assert_eq!(s.started_at, None);
        let s: Session = serde_json::from_str(
            r#"{"pid":42,"sessionId":"sid","cwd":"/tmp","startedAt":1793219579585}"#,
        )
        .unwrap();
        assert_eq!(s.started_at, Some(1_793_219_579_585));
    }
}
