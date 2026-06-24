//! Read `~/.claude/sessions/<pid>.json` — the canonical pid → sessionId + cwd
//! + status mapping Claude Code maintains — plus status glyph and JSONL path.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Session {
    pub pid: u32,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub status: String,
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

/// Load every `~/.claude/sessions/<pid>.json` into a pid-keyed map. Unreadable
/// or malformed files are silently skipped — a stale file shouldn't break the
/// whole panel.
pub fn load_all() -> HashMap<u32, Session> {
    let mut out = HashMap::new();
    let Ok(rd) = fs::read_dir(sessions_dir()) else {
        return out;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        if let Ok(sess) = serde_json::from_str::<Session>(&text) {
            out.insert(sess.pid, sess);
        }
    }
    out
}

/// Status glyph. Matches the old bash mapping:
/// `waiting`→`!` (needs input), `busy`→`~`, anything else (`idle`)→`✓`.
pub fn glyph(status: &str) -> char {
    match status {
        "waiting" => '!',
        "busy" => '~',
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
    fn glyphs() {
        assert_eq!(glyph("waiting"), '!');
        assert_eq!(glyph("busy"), '~');
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
    }
}
