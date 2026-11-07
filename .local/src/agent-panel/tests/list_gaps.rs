//! `list` exits 3 and names the gap when a live claude's session file will not read, so a caller
//! that reads a missing session as gone (fleet-dispatch reap) can tell a partial list from a whole
//! one (ar-916). HOME is a temp dir and TMUX_TMPDIR an empty one, so no live tmux server is read.

use std::fs;
use std::process::Command;

#[test]
fn a_live_pids_unreadable_session_file_is_a_gap_and_exit_3() {
    let dir = std::env::temp_dir().join(format!("agent-panel-gaps-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let sessions = dir.join("home/.claude/sessions");
    fs::create_dir_all(&sessions).unwrap();
    fs::create_dir_all(dir.join("tmux")).unwrap();
    let list = || {
        Command::new(env!("CARGO_BIN_EXE_agent-panel"))
            .args(["list", "--json"])
            .env("HOME", dir.join("home"))
            .env("TMUX_TMPDIR", dir.join("tmux"))
            .env_remove("TMUX")
            .output()
            .unwrap()
    };

    // A dead pid's broken file is a stale file, not a gap.
    fs::write(sessions.join("4294967.json"), "{").unwrap();
    let out = list();
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));

    // This test process is live: its broken file means the read is missing a session.
    let me = std::process::id();
    fs::write(sessions.join(format!("{me}.json")), "{\"pid\":").unwrap();
    let out = list();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(3), "{err}");
    assert!(err.contains(&format!("incomplete read: ~/.claude/sessions/{me}.json")), "{err}");
    fs::remove_dir_all(&dir).unwrap();
}
