//! Shared fixtures for the transcript tests.

use std::fs;
use std::io::Write;

pub fn tmpfile(tag: &str, lines: &[&str]) -> std::path::PathBuf {
    let dir = std::env::temp_dir();
    let path = dir.join(format!(
        "agent-panel-test-{}-{tag}.jsonl",
        std::process::id()
    ));
    let mut f = fs::File::create(&path).unwrap();
    writeln!(f, "{}", lines.join("\n")).unwrap();
    path
}

/// An entry at `min` minutes past 12:00, with the rest of its JSON from `body`.
pub fn at(min: u64, body: &str) -> String {
    let hour = 12 + min / 60;
    format!(
        r#"{{{body},"timestamp":"2026-10-{}T{:02}:{:02}:00.000Z"}}"#,
        30 + hour / 24,
        hour % 24,
        min % 60
    )
}
