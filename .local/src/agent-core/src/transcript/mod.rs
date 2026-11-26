//! Rules over a Claude transcript JSONL: the chooser row (summary, mode, plan), the fleet facts
//! `list --json` adds, the open question, time use and the turn around an ask. Each rule is
//! defined once here; every view reads it through this module.

use std::path::Path;

use serde_json::Value;

mod ask;
mod human;
mod plan;
mod prompt;
mod read;
mod said;
#[cfg(test)]
mod test_util;
mod time_use;
mod usage;

pub use ask::{asks_human_at, open_dialog_at, open_plan_at, open_question_at, Question};
pub use human::{human_said_at, HumanSaid};
pub use read::{clip, iso_epoch, str_of, tool_input};
pub use said::{said_around_at, Said};
pub use time_use::{time_use_at, TimeUse};
pub use usage::{context_window, uses, Uses};

/// The lines of a compiled-in `.config/agent-panel/*.conf`, trimmed, past its comments and blank
/// lines: the one parse every conf this module reads goes through.
fn conf_lines(conf: &'static str) -> impl Iterator<Item = &'static str> {
    conf.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
}

use plan::{plan_file, plan_slug};
use prompt::human_at;
use read::{collapse, read, truncate, turns};
use said::doing_said;
use time_use::time_use_and_open_job;
use usage::{compactions, edited_files, last_entry, last_usage};

/// What a chooser row needs from the transcript, from a single read of it.
pub struct RowInfo {
    /// One-line summary of the most recent turn.
    pub summary: String,
    /// The permission mode it shows: plan, manual or neither.
    pub mode: Mode,
    /// The plan it works: the stem of `plan_file` (`new-curious-garden`), empty for none.
    pub plan_slug: String,
}

pub fn row_info(path: &Path) -> RowInfo {
    let text = read(path);
    RowInfo {
        summary: last_event_in(&text),
        mode: Mode::of(permission_mode(&text).as_deref()),
        plan_slug: plan_slug(&plan_file(&text)),
    }
}

/// What `list --json` adds for fleet-sessions: context size, model, plan file, when the
/// session last wrote an entry, and the files it edited.
pub struct FleetInfo {
    /// input + cache_read + cache_creation tokens on the last main-thread assistant turn.
    pub context_tokens: u64,
    pub model: String,
    /// The session's plan file, empty when it has none.
    pub plan_file: String,
    /// Epoch seconds of the newest entry `timestamp`, None when no entry carries one.
    /// The file's mtime is not this: it moves about hourly with no new lines.
    pub last_entry: Option<u64>,
    /// Absolute paths the session changed through an edit tool (edit-tools.conf),
    /// in first-edit order. fleet-sessions counts only these as its dirt in a shared checkout.
    pub edited_files: Vec<String>,
    pub time_use: TimeUse,
    /// What the session is waiting on right now, from the jobs still open at its last entry:
    /// `human`, `gate`, `test`, `build`, `agent` (a background subagent), `jobs` (any other
    /// command) or `none`. Only the class, never the command. fleet-sessions trusts a `gate`,
    /// `test`, `build` or `agent` shell for longer than a `jobs` one, which is a sleep loop or a
    /// watch on a file.
    pub open_job: &'static str,
    /// The last main-thread tool call, `<Tool>: <description>`, empty when there is none.
    pub doing: String,
    /// The last main-thread assistant text on one line, clipped to `SAID_CHARS`.
    pub said: String,
    /// How many times the context was compacted.
    pub compactions: u64,
    /// Epoch seconds of the newest prompt the human typed (`human_at`), None when there is none.
    pub human_at: Option<u64>,
}

pub fn fleet_info(path: &Path) -> FleetInfo {
    let text = read(path);
    let (context_tokens, model) = last_usage(&text);
    let (doing, said) = doing_said(&text);
    let (time_use, open_job) = time_use_and_open_job(&text);
    FleetInfo {
        context_tokens,
        model,
        plan_file: plan_file(&text),
        last_entry: last_entry(&text),
        edited_files: edited_files(&text),
        time_use,
        open_job,
        doing,
        said,
        compactions: compactions(&text),
        human_at: human_at(&text),
    }
}

/// One-line summary of the most recent turn, for the chooser row.
pub fn last_event(path: &Path) -> String {
    last_event_in(&read(path))
}

fn last_event_in(text: &str) -> String {
    match turns(text).last() {
        None => "(no events)".to_string(),
        Some(v) => summarize(v),
    }
}

/// The permission mode a row marks. Manual is Claude's `default` mode, which
/// `manual-mode-investigate.sh` makes investigate-only: the session answers and changes nothing,
/// so a tab left in it does no work on its own. `acceptEdits`, bypass and the rest are `Other`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    #[default]
    Other,
    Plan,
    Manual,
}

impl Mode {
    pub fn of(permission_mode: Option<&str>) -> Mode {
        match permission_mode {
            Some("plan") => Mode::Plan,
            Some("default") => Mode::Manual,
            _ => Mode::Other,
        }
    }

    /// Its one-letter mark (`P`, `M`), empty for `Other`; also its map-file field.
    pub fn mark(self) -> &'static str {
        match self {
            Mode::Plan => "P",
            Mode::Manual => "M",
            Mode::Other => "",
        }
    }

    pub fn from_mark(mark: &str) -> Mode {
        match mark {
            "P" => Mode::Plan,
            "M" => Mode::Manual,
            _ => Mode::Other,
        }
    }
}

/// The session's current permission mode (`plan`, `default`, `bypassPermissions`,
/// ...): the last line carrying one. `~/.claude/sessions/<pid>.json` does not
/// record it, but Claude writes a `permission-mode` entry with every turn's
/// metadata (and stamps it on each prompt), so this trails a Shift+Tab toggle
/// by at most one turn. It is still right when a dialog hides the pane's footer.
fn permission_mode(text: &str) -> Option<String> {
    text.lines()
        .rev()
        .filter(|l| l.contains("\"permissionMode\""))
        .find_map(|l| {
            serde_json::from_str::<Value>(l)
                .ok()?
                .get("permissionMode")?
                .as_str()
                .map(str::to_string)
        })
}

fn summarize(v: &Value) -> String {
    if v.get("type").and_then(Value::as_str) == Some("assistant") {
        let Some(c) = v.pointer("/message/content/0") else {
            return "asst: ?".to_string();
        };
        match c.get("type").and_then(Value::as_str) {
            Some("tool_use") => {
                format!(
                    "tool: {}",
                    c.get("name").and_then(Value::as_str).unwrap_or("?")
                )
            }
            Some("text") => format!(
                "say: {}",
                truncate(
                    &collapse(c.get("text").and_then(Value::as_str).unwrap_or("")),
                    300
                )
            ),
            other => format!("asst: {}", other.unwrap_or("?")),
        }
    } else {
        "user: input".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_util::*;
    use std::fs;

    #[test]
    fn summarizes_tool_use() {
        let p = tmpfile(
            "tool",
            &[
                r#"{"type":"user","message":{"content":"hi"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            ],
        );
        assert_eq!(last_event(&p), "tool: Bash");
        fs::remove_file(&p).ok();
    }

    #[test]
    fn summarizes_text_and_missing() {
        let p = tmpfile(
            "text",
            &[
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello  world"}]}}"#,
            ],
        );
        assert_eq!(last_event(&p), "say: hello world");
        fs::remove_file(&p).ok();
        assert_eq!(last_event(Path::new("/no/such/file.jsonl")), "(no events)");
    }

    #[test]
    fn plan_mode_follows_the_last_mode_line() {
        let p = tmpfile(
            "plan",
            &[
                r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
                r#"{"type":"user","permissionMode":"plan","message":{"content":"plan it"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
            ],
        );
        let info = row_info(&p);
        assert_eq!(info.mode, Mode::Plan);
        assert_eq!(info.summary, "tool: Read");
        fs::remove_file(&p).ok();

        // Leaving plan mode (ExitPlanMode approved) writes a newer mode line.
        let p = tmpfile(
            "built",
            &[
                r#"{"type":"permission-mode","permissionMode":"plan"}"#,
                r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
            ],
        );
        assert_eq!(row_info(&p).mode, Mode::Other);
        fs::remove_file(&p).ok();

        // Shift+Tab back to manual (`default`) marks it manual; acceptEdits is not manual.
        let p = tmpfile(
            "manual",
            &[
                r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
                r#"{"type":"permission-mode","permissionMode":"default"}"#,
            ],
        );
        assert_eq!(row_info(&p).mode, Mode::Manual);
        fs::remove_file(&p).ok();
        let p = tmpfile(
            "edits",
            &[r#"{"type":"permission-mode","permissionMode":"acceptEdits"}"#],
        );
        assert_eq!(row_info(&p).mode, Mode::Other);
        fs::remove_file(&p).ok();

        assert_eq!(row_info(Path::new("/no/such/file.jsonl")).mode, Mode::Other);
    }

    #[test]
    fn the_row_names_its_plan_by_slug() {
        let p = tmpfile(
            "slug",
            &[
                r#"{"type":"assistant","planFilePath":"/h/.claude/plans/new-curious-garden.md","message":{"content":[]}}"#,
            ],
        );
        assert_eq!(row_info(&p).plan_slug, "new-curious-garden");
        fs::remove_file(&p).ok();
        assert_eq!(row_info(Path::new("/no/such/file.jsonl")).plan_slug, "");
    }

    #[test]
    fn fleet_info_reads_usage_and_plan() {
        let p = tmpfile(
            "fleet",
            &[
                r#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":8}}}"#,
                r#"{"type":"attachment","attachment":{"planFilePath":"/h/.claude/plans/older.md"}}"#,
                r#"{"type":"attachment","attachment":{"planFilePath":"/h/.claude/plans/mine.md"}}"#,
                r#"{"type":"user","message":{"content":"see /h/.claude/plans/other.md and /h/.claude/plans/other.md"}}"#,
                r#"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":5}}}"#,
                r#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}"#,
            ],
        );
        let info = fleet_info(&p);
        assert_eq!(info.context_tokens, 110);
        assert_eq!(info.model, "claude-opus-5-5");
        assert_eq!(info.plan_file, "/h/.claude/plans/mine.md");
        fs::remove_file(&p).ok();
    }
}
