//! Reading a transcript: its whole text, its tail, and the entry helpers every rule shares.

use std::fs;
use std::path::Path;

use serde_json::Value;

/// Collapse runs of whitespace to single spaces and trim.
pub(super) fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Truncate to `n` characters (char-safe, never splits a multibyte char).
pub(super) fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// The last `n` lines of a transcript's text.
pub(super) fn tail_lines(text: &str, n: usize) -> Vec<&str> {
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].to_vec()
}

/// Parse JSONL lines, keeping only assistant/user events in order.
pub(super) fn turns(text: &str) -> Vec<Value> {
    tail_lines(text, 200)
        .iter()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| {
            matches!(
                v.get("type").and_then(Value::as_str),
                Some("assistant") | Some("user")
            )
        })
        .collect()
}

/// Whole transcript text. Empty on any read error.
pub(super) fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// An entry the session wrote itself: a main-thread assistant turn, not a subagent's.
pub(super) fn own_turn(v: &Value) -> bool {
    v.get("type").and_then(Value::as_str) == Some("assistant")
        && v.get("isSidechain").and_then(Value::as_bool) != Some(true)
}

pub(super) fn content_blocks(v: &Value) -> &[Value] {
    v.pointer("/message/content")
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// The most of one message a card or a transcript page shows.
const MAX_TEXT: usize = 4000;

/// `s` cut to `MAX_TEXT` characters, marked `[...]` when cut.
pub fn clip(s: &str) -> String {
    if s.chars().count() <= MAX_TEXT {
        return s.to_string();
    }
    let mut out: String = s.chars().take(MAX_TEXT).collect();
    out.push_str("\n[...]");
    out
}

/// A JSON string's text, empty for anything else.
pub fn str_of(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or("").to_string()
}

/// A tool call's input: the command or path when there is an obvious one, else the JSON.
pub fn tool_input(v: Option<&Value>) -> String {
    let Some(v) = v else { return String::new() };
    for key in [
        "command",
        "file_path",
        "pattern",
        "url",
        "prompt",
        "description",
    ] {
        if let Some(s) = v.get(key).and_then(Value::as_str) {
            return s.to_string();
        }
    }
    v.to_string()
}

/// `2026-10-27T22:31:45.360Z` (UTC, optional fraction) -> epoch seconds. Anything else is None.
pub(super) fn iso_epoch(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
        || !s.ends_with('Z')
    {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Days from 1970-01-01 to y-m-d (Howard Hinnant's days_from_civil).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + hh * 3600 + mm * 60 + ss).ok()
}
