//! One queue item's history, for the opened Queue row on both hub surfaces: what happened to it,
//! one line per step, from the ingest record (`notes log --item <slug> --json`, written by
//! `chain-event.sh`). Read only when a row is opened; the record is never written here.

use crate::queue::is_slug;
use crate::session_actions::Runner;
use serde::{Deserialize, Serialize};

/// The lines a history keeps, newest last.
pub const KEEP: usize = 20;

/// How far back the record is read, in days. An item older than this shows its last month.
pub const DAYS: u32 = 30;

/// One event as `notes log --json` prints it; the fields a line is made from.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct Event {
    ts: String,
    action: String,
    to: String,
    why: Option<String>,
    pr: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Line {
    /// The event's timestamp as the record holds it (RFC 3339).
    pub at: String,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct History {
    /// Times the item went to running (a move to running, or an add straight into it).
    pub attempts: usize,
    /// Steps worth a line, before the cut to [`KEEP`].
    pub steps: usize,
    /// The last [`KEEP`] steps, oldest first.
    pub lines: Vec<Line>,
    /// How far back it was read ([`DAYS`]).
    pub days: u32,
}

pub fn read(runner: &dyn Runner, slug: &str) -> Result<History, String> {
    if !is_slug(slug) {
        return Err(format!("not a queue slug: {slug}"));
    }
    let argv = [
        "notes",
        "log",
        "--item",
        slug,
        "--days",
        &DAYS.to_string(),
        "--json",
    ]
    .map(String::from);
    Ok(build(&runner.run(&argv)?))
}

/// The history from the record's JSON lines; a line that does not parse is skipped.
pub fn build(log: &str) -> History {
    let events: Vec<Event> = log
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let attempts = events
        .iter()
        .filter(|e| matches!(e.action.as_str(), "item-moved" | "item-added") && e.to == "running")
        .count();
    let mut lines: Vec<Line> = events
        .iter()
        .filter_map(|e| {
            text(e).map(|text| Line {
                at: e.ts.clone(),
                text,
            })
        })
        .collect();
    let steps = lines.len();
    lines.drain(..steps.saturating_sub(KEEP));
    History {
        attempts,
        steps,
        lines,
        days: DAYS,
    }
}

/// The line one event reads as, or None for bookkeeping (lane, cost, minutes, claims, the
/// board's own add and start of the item's row).
fn text(e: &Event) -> Option<String> {
    let why = e.why.as_deref().unwrap_or("");
    let pr = e.pr.as_deref().unwrap_or("");
    let joined = |head: &str, tail: &str| {
        if tail.is_empty() {
            head.to_string()
        } else {
            format!("{head}, {tail}")
        }
    };
    Some(match e.action.as_str() {
        "item-added" => joined("added", &e.to),
        "item-moved" if !why.is_empty() => why.to_string(),
        "item-moved" => format!("-> {}", e.to),
        "item-cancelled" => "cancelled".into(),
        "started" if !e.to.is_empty() => joined(&format!("started on {}", e.to), why),
        "reaped" => joined("reaped", why),
        "parked" => "session parked".into(),
        "unparked" => "session unparked".into(),
        "merged" => format!("merged {pr}").trim_end().into(),
        "land-failed" => joined("land failed", why),
        "item-set" => return set_text(why, pr),
        _ => return None,
    })
}

/// An `item-set` worth a line: a note, a fix-ci try, a red PR handed to the human, a PR, a rewrite.
/// Its `why` is every `key=value` the one `agent-queue set` call took, so each key is read, and
/// a key set to nothing (cleared) says nothing.
fn set_text(why: &str, pr: &str) -> Option<String> {
    if why.starts_with("task rewritten") {
        return Some("task rewritten".into());
    }
    let mut said = Vec::new();
    for (k, v) in pairs(why) {
        if v.is_empty() {
            continue;
        }
        match k {
            "fix_tries" => said.push(format!("fix-ci try {}", v.split(' ').next().unwrap_or(v))),
            "fix_human" => said.push("PR still red after fix-ci, yours".into()),
            "pr" => said.push(format!("PR {}", if pr.is_empty() { v } else { pr })),
            "note" => said.push(format!("note: {v}")),
            _ => {}
        }
    }
    (!said.is_empty()).then(|| said.join("; "))
}

/// The `key=value` pairs of a set's `why`: a word that starts `key=` opens a pair and the words
/// after it, up to the next, are its value (a note has spaces).
fn pairs(why: &str) -> Vec<(&str, &str)> {
    let is_key = |w: &str| {
        w.split_once('=').is_some_and(|(k, _)| {
            !k.is_empty() && k.chars().all(|c| c.is_ascii_lowercase() || c == '_')
        })
    };
    let mut starts: Vec<usize> = Vec::new();
    let mut at = 0;
    for w in why.split(' ') {
        if is_key(w) {
            starts.push(at);
        }
        at += w.len() + 1;
    }
    starts
        .iter()
        .enumerate()
        .map(|(n, &a)| {
            let end = starts.get(n + 1).map_or(why.len(), |&b| b - 1);
            let (k, v) = why[a..end].split_once('=').unwrap_or_default();
            (k, v.trim())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(
                argv,
                ["notes", "log", "--item", "ucp-526", "--days", "30", "--json"]
            );
            self.0.clone()
        }
    }

    fn ev(action: &str, to: &str, why: &str, pr: &str) -> String {
        serde_json::json!({
            "ts": "2026-11-12T07:04:21-08:00", "action": action, "to": to,
            "why": (!why.is_empty()).then_some(why), "pr": (!pr.is_empty()).then_some(pr),
        })
        .to_string()
    }

    #[test]
    fn steps_read_as_lines_and_bookkeeping_is_dropped() {
        let log = [
            ev("item-added", "queued", "", ""),
            ev("item-set", "", "lane=agent", ""),
            ev("item-moved", "running", "queued -> running", ""),
            ev("item-claimed", "", "e0ac7d14", ""),
            ev("started", "lab:ucp-agent-10", "sol on codex", ""),
            ev("added", "", "", ""),
            ev("started", "", "", ""),
            ev("item-set", "", "cost_usd=1.13 work_min=120", "o/r#2134"),
            ev("item-set", "", "pr=o/r#2134", "o/r#2134"),
            ev(
                "item-set",
                "",
                "fix_tries=2 94193c mode=oneshot note=red at 9419",
                "o/r#2134",
            ),
            ev(
                "item-set",
                "",
                "pr_owner=fix fix_human= fix_tries= land_tries=",
                "",
            ),
            ev("item-set", "", "fix_human=ba7f53", "o/r#2134"),
            ev("item-set", "", "note=held for the night", "o/r#2134"),
            ev("item-set", "", "task rewritten, was: old words", "o/r#2134"),
            ev("reaped", "", "item was running", ""),
            ev("land-failed", "", "checks: Checks", "o/r#2134"),
            ev("merged", "", "", "o/r#2134"),
            "not json".into(),
        ]
        .join("\n");
        let h = read(&Fake(Ok(log)), "ucp-526").unwrap();
        let texts: Vec<&str> = h.lines.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(
            texts,
            [
                "added, queued",
                "queued -> running",
                "started on lab:ucp-agent-10, sol on codex",
                "PR o/r#2134",
                "fix-ci try 2; note: red at 9419",
                "PR still red after fix-ci, yours",
                "note: held for the night",
                "task rewritten",
                "reaped, item was running",
                "land failed, checks: Checks",
                "merged o/r#2134",
            ]
        );
        assert_eq!((h.attempts, h.steps), (1, 11));
        assert_eq!(h.lines[0].at, "2026-11-12T07:04:21-08:00");
    }

    #[test]
    fn a_long_history_keeps_its_last_lines_and_counts_every_attempt() {
        let log = (0..30)
            .map(|_| ev("item-moved", "running", "queued -> running", ""))
            .chain([ev("merged", "", "", "o/r#1")])
            .collect::<Vec<_>>()
            .join("\n");
        let h = build(&log);
        assert_eq!((h.attempts, h.steps, h.lines.len()), (30, 31, KEEP));
        assert_eq!(h.lines.last().unwrap().text, "merged o/r#1");
    }

    #[test]
    fn a_bad_slug_is_refused_before_anything_runs_and_a_failed_read_is_an_error() {
        struct Never;
        impl Runner for Never {
            fn run(&self, _: &[String]) -> Result<String, String> {
                panic!("ran")
            }
        }
        assert!(read(&Never, "--days").is_err());
        assert!(read(&Never, "a b").is_err());
        assert_eq!(
            read(&Fake(Err("no notes".into())), "ucp-526"),
            Err("no notes".into())
        );
        assert_eq!(build("").lines, []);
    }
}
