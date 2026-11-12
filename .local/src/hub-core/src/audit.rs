//! The operator audit log: one JSON line for each change made through agent-web or the hub TUI,
//! or with agent-hold or claude-acct park, at `~/.agent/audit/actions.jsonl` (`AGENT_AUDIT_LOG`
//! overrides). Log > Actions reads it (`actions::parse_audit`). A line:
//!
//! ```json
//! {"at":1762970000,"actor":"kblack0610","action":"queue.bumped","target":"fix-x",
//!  "outcome":"ok","via":"web","to":{"priority":"high"}}
//! ```
//!
//! `action` is `<noun>.<verb in the past tense>`; `actor` is the signed-in login (web), the local
//! user (hub) or the session (cli); `outcome` is `ok` or `failed: <why>`; `from` is what the
//! target held before, when the writer knew it, and `to` what was asked. `.local/lib/audit.sh`
//! writes the same shape from shell.

use std::io::Write as _;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Set to this process's pid on every command `session_actions::System` runs: a shell tool that
/// writes its own line (`.local/lib/audit.sh`) sees its parent's pid there and leaves the line to
/// the caller, which records it under the person who asked. A grandchild never matches.
pub const AUDITED_ENV: &str = "AGENT_AUDITED";

/// A target, or a string in `from` or `to`, longer than this is cut: the log names a change, it
/// does not keep a copy of a note or a row.
pub const TEXT_MAX: usize = 200;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Entry {
    /// Epoch seconds.
    pub at: i64,
    pub actor: String,
    pub action: String,
    pub target: String,
    pub outcome: String,
    /// `web`, `hub` or `cli`.
    pub via: String,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub from: Value,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub to: Value,
}

impl Entry {
    /// An entry stamped now, `ok` until `outcome_of` says otherwise.
    pub fn new(actor: &str, action: &str, target: &str, via: &str) -> Entry {
        Entry {
            at: crate::jobs::now(),
            actor: actor.into(),
            action: action.into(),
            target: cut(target),
            outcome: "ok".into(),
            via: via.into(),
            from: Value::Null,
            to: Value::Null,
        }
    }

    /// What was asked. An object keeps only the fields that say something: null, empty strings
    /// and empty lists are dropped, and an object left empty is no `to` at all.
    pub fn to(mut self, v: Value) -> Entry {
        self.to = match clip(v) {
            Value::Object(o) => {
                let said: serde_json::Map<String, Value> = o
                    .into_iter()
                    .filter(|(_, v)| !(v.is_null() || v == "" || v == &Value::Array(vec![])))
                    .collect();
                if said.is_empty() {
                    Value::Null
                } else {
                    Value::Object(said)
                }
            }
            v => v,
        };
        self
    }

    pub fn outcome_of<T>(mut self, r: &Result<T, String>) -> Entry {
        if let Err(e) = r {
            self.outcome = failed(e);
        }
        self
    }

    pub fn ok(&self) -> bool {
        self.outcome == "ok"
    }
}

/// `failed: <why>`, on one line and clipped.
pub fn failed(why: &str) -> String {
    let one: String = why.split_whitespace().collect::<Vec<_>>().join(" ");
    format!("failed: {}", cut(&one))
}

fn cut(s: &str) -> String {
    match s.char_indices().nth(TEXT_MAX) {
        Some((i, _)) => format!("{}...", &s[..i]),
        None => s.to_string(),
    }
}

/// `v` with every string longer than TEXT_MAX cut.
pub fn clip(v: Value) -> Value {
    match v {
        Value::String(s) => Value::String(cut(&s)),
        Value::Array(a) => Value::Array(a.into_iter().map(clip).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, clip(v))).collect()),
        v => v,
    }
}

pub fn path() -> PathBuf {
    std::env::var_os("AGENT_AUDIT_LOG")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".agent/audit/actions.jsonl")
        })
}

/// Append one line to `path` in a single write, so lines from two writers never interleave. A new
/// log is readable only by its owner: it says what was typed where.
pub fn append_to(path: &std::path::Path, e: &Entry) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| format!("{}: {err}", dir.display()))?;
    }
    let mut line = serde_json::to_string(e).map_err(|err| err.to_string())?;
    line.push('\n');
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .and_then(|mut f| f.write_all(line.as_bytes()))
        .map_err(|err| format!("{}: {err}", path.display()))
}

/// Append `e` to the log. A line that cannot be written says so on stderr (the journal for
/// agent-web), never silently: the change itself already happened.
pub fn record(e: &Entry) {
    if let Err(err) = append_to(&path(), e) {
        eprintln!("audit: {} {} not recorded: {err}", e.action, e.target);
    }
}

/// Who acts from a terminal on this machine: the hub TUI's actor.
pub fn local_actor() -> String {
    std::env::var("USER")
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| "local".into())
}

/// The past tense of a verb the surfaces use (session actions, board verbs), for `<noun>.<verb>`.
pub fn past(verb: &str) -> String {
    match verb {
        "done" => "done".into(),
        "stop" | "drop" => format!("{verb}ped"),
        "tag" => "tagged".into(),
        "cancel" => "canceled".into(),
        "approve-plan" => "plan-approved".into(),
        v if v.ends_with('e') => format!("{v}d"),
        v => format!("{v}ed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_verb_in_use_has_a_past_tense() {
        let cases = [
            ("interrupt", "interrupted"),
            ("park", "parked"),
            ("unpark", "unparked"),
            ("move", "moved"),
            ("stop", "stopped"),
            ("cancel", "canceled"),
            ("approve-plan", "plan-approved"),
            ("add", "added"),
            ("done", "done"),
            ("start", "started"),
            ("drop", "dropped"),
            ("promote", "promoted"),
            ("demote", "demoted"),
            ("edit", "edited"),
            ("tag", "tagged"),
        ];
        for (v, p) in cases {
            assert_eq!(past(v), p, "{v}");
        }
        for a in crate::session_actions::Action::ALL {
            assert!(!past(a.name()).contains("eed"), "{}", a.name());
        }
    }

    #[test]
    fn a_line_is_appended_whole_and_reads_back() {
        let dir = std::env::temp_dir().join(format!("hub-core-audit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p = dir.join("audit/actions.jsonl");
        let long = "x".repeat(TEXT_MAX + 50);
        let e = Entry::new("ken", "queue.bumped", "fix-x", "web")
            .to(json!({"priority": "high", "text": long}))
            .outcome_of::<()>(&Err("agent-queue: no\nsuch item".into()));
        append_to(&p, &e).unwrap();
        append_to(&p, &Entry::new("ken", "ask.answered", "abc", "hub")).unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        let back: Vec<Entry> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].outcome, "failed: agent-queue: no such item");
        assert_eq!(
            back[0].to["text"].as_str().unwrap().len(),
            TEXT_MAX + "...".len()
        );
        assert!(back[1].ok());
        assert!(!text.lines().nth(1).unwrap().contains("\"from\""));
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&p).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "the log is its owner's only");
        let e = Entry::new("ken", "board.edited", &long, "hub");
        assert_eq!(
            e.target.len(),
            TEXT_MAX + "...".len(),
            "a long target is cut"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
