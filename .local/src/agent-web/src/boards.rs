//! The hub boards, read for the browser. Each board's own tool writes the files read here
//! (`fleet-sessions --write`, its watch ticks, `day-log`); this module only parses them, so
//! the web tabs and the tmux boards can never disagree about what happened.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use agent_panel::session;

/// Transitions sent to the Watch tab: about a day of a busy fleet, sync lines included.
pub const WATCH_LOG_LINES: usize = 1500;

pub fn fleet_state() -> PathBuf {
    session::home().join(".local/state/fleet/state.json")
}

pub fn shepherd_dir() -> PathBuf {
    session::home().join(".agent/shepherd")
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn watch_survives_missing_files() {
        let w = watch(Path::new("/nonexistent/state.json"), Path::new("/nonexistent/log"));
        assert_eq!(w.state, Value::Null);
        assert!(w.transitions.is_empty());
    }
}
