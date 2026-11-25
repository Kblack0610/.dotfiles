//! Prompts: which user entries the human typed, and which our own tooling typed for them.

use serde_json::Value;

use super::read::iso_epoch;

/// The newest timestamp of a prompt the human typed: a `typed_prompt` that is not one our own
/// tooling types into the pane (`fleet_typed`), or a message they sent mid-turn (`queued_prompt`).
pub(super) fn human_at(text: &str) -> Option<u64> {
    text.lines()
        .rev()
        .filter(|l| l.contains("\"timestamp\":\""))
        .find(|l| human_typed(l))
        .and_then(|l| serde_json::from_str::<Value>(l).ok())
        .and_then(|v| {
            v.get("timestamp")
                .and_then(Value::as_str)
                .and_then(iso_epoch)
        })
}

/// A typed prompt the human sent, not one our tooling typed into the pane (a resume is no typed
/// prompt at all, a task is one but not the human's).
pub(super) fn human_typed(line: &str) -> bool {
    typed_prompt(line).is_some_and(|p| !fleet_typed(&p)) || queued_prompt(line).is_some()
}

/// The one table of prompts the fleet types as if the human had (the shepherd's close, a
/// restore, a dispatch brief, an ask's answer, a park, move or wake resume). Read as typed, a
/// dispatch brief held each dispatched session open for the human keep after its start
/// (2026-11-17).
const TYPED_PREFIXES: &str = include_str!("../../../../../.config/agent-panel/typed-prefixes.conf");

/// The table's `<kind> <text>` lines.
fn typed_entries() -> impl Iterator<Item = (&'static str, &'static str)> {
    TYPED_PREFIXES
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once(char::is_whitespace))
        .map(|(kind, text)| (kind, text.trim()))
}

/// The kind (`task` or `resume`) of the first table line a line of `prompt`, leading whitespace
/// aside, starts with, followed by whitespace or the end of the line. A brief opens with the
/// entry skill the human types too ("/one-shot ..."), so any line counts, not just the first.
/// `.local/lib/typed-prefixes.sh` and claude-recall's `fleet_typed` are the same rule, held to
/// `tests/fixtures/typed-prompts.tsv`.
fn typed_kind(prompt: &str) -> Option<&'static str> {
    prompt.lines().map(str::trim_start).find_map(|line| {
        typed_entries()
            .find(|(_, text)| {
                line.strip_prefix(text)
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with(char::is_whitespace))
            })
            .map(|(kind, _)| kind)
    })
}

fn fleet_typed(prompt: &str) -> bool {
    typed_kind(prompt).is_some()
}

/// The words of a message the human sent while the session worked. The harness queues it and
/// delivers it mid-turn as a `queued_command` attachment, never as a user entry, so read only as
/// a user entry an answer typed mid-turn was refused (ar-5269: 'ok yes' in session dde1b8cd). A
/// task notice or a peer's message queued the same way names another origin and is not theirs.
pub(super) fn queued_prompt(line: &str) -> Option<String> {
    if !line.contains("\"queued_command\"") {
        return None;
    }
    let v = serde_json::from_str::<Value>(line).ok()?;
    let a = v.get("attachment")?;
    if v.get("type").and_then(Value::as_str) != Some("attachment")
        || v.get("isSidechain").and_then(Value::as_bool) == Some(true)
        || a.get("type").and_then(Value::as_str) != Some("queued_command")
        || a.get("commandMode").and_then(Value::as_str) != Some("prompt")
        || a.pointer("/origin/kind").and_then(Value::as_str) != Some("human")
    {
        return None;
    }
    let s = a.get("prompt")?.as_str()?.trim();
    (!s.is_empty() && !HARNESS.iter().any(|h| s.starts_with(h)) && !fleet_typed(s))
        .then(|| s.to_string())
}

/// The text of a prompt the human typed, for a main-thread user entry that is one: a string,
/// not a tool result, a reminder or a notice the harness queued.
pub(super) fn typed_prompt(line: &str) -> Option<String> {
    if !line.contains("\"type\":\"user\"") || line.contains("\"tool_result\"") {
        return None;
    }
    let v = serde_json::from_str::<Value>(line).ok()?;
    if v.get("type").and_then(Value::as_str) != Some("user")
        || v.get("isMeta").and_then(Value::as_bool) == Some(true)
        || v.get("isSidechain").and_then(Value::as_bool) == Some(true)
        || v.get("isCompactSummary").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let s = v.pointer("/message/content")?.as_str()?.trim();
    // A resume only says carry on: the turn it continues began at the prompt before it.
    if s.is_empty() || HARNESS.iter().any(|h| s.starts_with(h)) || typed_kind(s) == Some("resume") {
        return None;
    }
    // A typed slash command is stored as tags; the human typed "/name args".
    Some(match tag(s, "command-name") {
        Some(name) => format!("{name} {}", tag(s, "command-args").unwrap_or(""))
            .trim()
            .to_string(),
        None => s.to_string(),
    })
}

/// Text the harness puts in a user turn that nobody typed: its tags and its prose. The prose ones
/// are claude-recall's HARNESS_PREFIXES; a test keeps the two lists in step. What our own tooling
/// types is a prompt, read by `fleet_typed`.
const HARNESS: &[&str] = &[
    "<task-notification",
    "<system-reminder",
    "<cross-session-message",
    "<local-command",
    "This session is being continued",
    "Stop hook feedback",
    "[Request interrupted",
    "Another Claude session sent",
    "Caveat:",
];

fn tag<'a>(s: &'a str, name: &str) -> Option<&'a str> {
    let start = s.find(&format!("<{name}>"))? + name.len() + 2;
    let len = s[start..].find(&format!("</{name}>"))?;
    Some(s[start..start + len].trim())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_util::*;
    use std::fs;

    #[test]
    fn human_at_is_the_newest_prompt_the_human_typed_not_our_tooling() {
        let base = iso_epoch("2026-10-30T12:00:00Z").unwrap();
        let typed = at(
            5,
            r#""type":"user","message":{"content":"keep going on the runners"}"#,
        );
        let lines = [
            at(0, r#""type":"user","message":{"content":"start the plan"}"#),
            typed.clone(),
            at(
                10,
                r#""type":"assistant","message":{"content":[{"type":"text","text":"done"}]}"#,
            ),
            // Every sender our tooling types with, and the harness, after it: none is the human.
            at(
                20,
                r#""type":"user","message":{"content":"<command-message>wind-down</command-message>\n<command-name>/wind-down</command-name>\n<command-args>auto</command-args>"}"#,
            ),
            at(
                21,
                r#""type":"user","message":{"content":"<command-name>/wind-down</command-name>"}"#,
            ),
            at(
                22,
                r#""type":"user","message":{"content":"fleet-dispatch restore reopened this session after its tmux server was lost"}"#,
            ),
            at(
                23,
                r#""type":"user","message":{"content":"This session was parked by claude-acct"}"#,
            ),
            at(
                24,
                r#""type":"user","message":{"content":"<task-notification> done"}"#,
            ),
            at(
                25,
                r#""type":"user","isMeta":true,"message":{"content":"a reminder"}"#,
            ),
            at(
                27,
                r#""type":"user","message":{"content":"Answer to ask bnLnIa: done at 16:30"}"#,
            ),
            at(
                26,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"x"}]}"#,
            ),
            at(
                28,
                r#""type":"user","message":{"content":"<command-message>one-shot</command-message>\n<command-name>/one-shot</command-name>\n<command-args>Phase 2 of the plan\n\nThis is agent-queue item plan-p2, and that item is its record.</command-args>"}"#,
            ),
            at(
                29,
                r#""type":"user","message":{"content":"This is agent-queue item p. Your last run on it stopped at the plan's usage limit."}"#,
            ),
        ];
        assert_eq!(human_at(&lines.join("\n")), Some(base + 5 * 60));
        // Negative control: a typed slash command of the human's own does count.
        let mine = at(
            30,
            r#""type":"user","message":{"content":"<command-name>/review</command-name>"}"#,
        );
        assert_eq!(
            human_at(&[lines.join("\n"), mine].join("\n")),
            Some(base + 30 * 60)
        );
        // And so does a /one-shot the human typed: the entry skill alone is not a dispatch brief.
        let shot = at(
            31,
            r#""type":"user","message":{"content":"<command-name>/one-shot</command-name>\n<command-args>fix the chip</command-args>"}"#,
        );
        assert_eq!(
            human_at(&[lines.join("\n"), shot].join("\n")),
            Some(base + 31 * 60)
        );
        // And so does the human quoting a brief mid-sentence: only a line that starts with it is one.
        let quote = at(
            32,
            r#""type":"user","message":{"content":"why does it say This is agent-queue item foo?"}"#,
        );
        assert_eq!(
            human_at(&[lines.join("\n"), quote].join("\n")),
            Some(base + 32 * 60)
        );
        // And so does a message the human sent mid-turn; a peer's queued the same way does not.
        let queued = |min, kind| {
            at(
                min,
                &format!(
                    r#""type":"attachment","attachment":{{"type":"queued_command","prompt":"ok yes","commandMode":"prompt","origin":{{"kind":"{kind}"}}}}"#
                ),
            )
        };
        assert_eq!(
            human_at(&[lines.join("\n"), queued(33, "human"), queued(34, "peer")].join("\n")),
            Some(base + 33 * 60)
        );
        assert_eq!(human_at(&lines[2..].join("\n")), None);
    }

    #[test]
    fn harness_prefixes_cover_claude_recalls() {
        let src = fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../bin/claude-recall"
        ))
        .unwrap();
        let start = src
            .find("HARNESS_PREFIXES = (")
            .expect("claude-recall lost HARNESS_PREFIXES");
        let body = &src[start..start + src[start..].find(')').unwrap()];
        let theirs: Vec<&str> = body.split('"').skip(1).step_by(2).collect();
        assert!(theirs.len() >= 5, "{theirs:?}");
        for p in theirs {
            assert!(
                HARNESS.contains(&p),
                "claude-recall skips {p:?}; add it to HARNESS"
            );
        }
    }

    #[test]
    fn fleet_typed_follows_the_shared_golden() {
        let golden = include_str!("../../../../../tests/fixtures/typed-prompts.tsv");
        let mut n = 0;
        for l in golden
            .lines()
            .filter(|l| !l.starts_with('#') && !l.is_empty())
        {
            let (want, text) = l.split_once('\t').expect("fleet|human<TAB>prompt");
            let text = text.replace("\\n", "\n");
            assert_eq!(fleet_typed(&text), want == "fleet", "{text:?}");
            n += 1;
        }
        assert!(n >= 10, "{n} cases");
        // Every line of the table is a kind the readers know, with text after it.
        for line in TYPED_PREFIXES
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        {
            let (kind, text) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
            assert!(
                matches!(kind, "task" | "resume") && !text.trim().is_empty(),
                "typed-prefixes.conf: {line:?} is not `task|resume <text>`"
            );
        }
        // A resume opens no turn; a task is a typed prompt that is not the human's.
        let resume =
            r#"{"type":"user","message":{"content":"This session was parked to save usage"}}"#;
        let task = r#"{"type":"user","message":{"content":"Answer to ask AbC: yes"}}"#;
        assert_eq!(typed_prompt(resume), None);
        assert!(typed_prompt(task).is_some() && !human_typed(task));
    }
}
