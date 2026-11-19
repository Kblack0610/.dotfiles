//! What the session did and said: its last call and text, and the turn that posted an ask.

use std::path::Path;

use serde_json::Value;

use super::prompt::typed_prompt;
use super::read::{collapse, content_blocks, own_turn, read, truncate};

const SAID_CHARS: usize = 120;

/// The last tool call and the last text of the session's own turns. Only a tool's description
/// is copied, never a Bash command, which can hold a secret.
pub(super) fn doing_said(text: &str) -> (String, String) {
    let (mut doing, mut said) = (None, None);
    for line in text.lines().rev() {
        if doing.is_some() && said.is_some() {
            break;
        }
        if !line.contains("\"type\":\"assistant\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if !own_turn(&v) {
            continue;
        }
        let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else {
            continue;
        };
        for c in blocks.iter().rev() {
            match c.get("type").and_then(Value::as_str) {
                Some("tool_use") if doing.is_none() => {
                    let name = c.get("name").and_then(Value::as_str).unwrap_or("?");
                    let desc = c
                        .pointer("/input/description")
                        .and_then(Value::as_str)
                        .map(collapse)
                        .unwrap_or_default();
                    doing = Some(if desc.is_empty() {
                        name.to_string()
                    } else {
                        format!("{name}: {}", truncate(&desc, SAID_CHARS))
                    });
                }
                Some("text") if said.is_none() => {
                    let t = collapse(c.get("text").and_then(Value::as_str).unwrap_or(""));
                    if !t.is_empty() {
                        said = Some(truncate(&t, SAID_CHARS));
                    }
                }
                _ => {}
            }
        }
    }
    (doing.unwrap_or_default(), said.unwrap_or_default())
}

/// The turn that posted an ask, for its card: the prompt the human typed to start that turn and
/// everything the session wrote in it, up to the next prompt.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub struct Said {
    /// The session's first typed prompt: the request it was started with.
    pub first: String,
    /// The typed prompt the asking turn answered.
    pub prompt: String,
    /// The assistant's own text blocks in that turn, oldest first.
    pub said: Vec<String>,
}

/// `said_around` over the transcript at `path`.
pub fn said_around_at(path: &Path, id: &str) -> Option<Said> {
    said_around(&read(path), id)
}

/// The turn around ask `id`. The post is found by its output: `agent-ask post` prints the id on a
/// line of its own, in the result of the call that ran it. Only the lines of that one turn are
/// parsed, so a 90 MB transcript costs a string search. None when no tool result prints the id.
fn said_around(text: &str, id: &str) -> Option<Said> {
    if id.is_empty() {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    let at = lines
        .iter()
        .position(|l| l.contains("\"tool_result\"") && l.contains(id) && prints_id(l, id))?;
    let start = (0..at).rev().find(|&i| typed_prompt(lines[i]).is_some());
    let end = (at + 1..lines.len())
        .find(|&i| typed_prompt(lines[i]).is_some())
        .unwrap_or(lines.len());
    let prompt = start
        .and_then(|i| typed_prompt(lines[i]))
        .unwrap_or_default();
    let mut said = Vec::new();
    for line in &lines[start.map_or(0, |i| i + 1)..end] {
        if !line.contains("\"type\":\"assistant\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if !own_turn(&v) {
            continue;
        }
        for b in content_blocks(&v) {
            if b.get("type").and_then(Value::as_str) == Some("text") {
                let t = b.get("text").and_then(Value::as_str).unwrap_or("").trim();
                if !t.is_empty() {
                    said.push(t.to_string());
                }
            }
        }
    }
    let first = lines
        .iter()
        .find_map(|l| typed_prompt(l))
        .unwrap_or_default();
    Some(Said {
        first,
        prompt,
        said,
    })
}

/// A tool result entry whose text has `id` alone on a line.
fn prints_id(line: &str, id: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return false;
    };
    let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else {
        return false;
    };
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        .any(|b| {
            let text = match b.get("content") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Array(parts)) => parts
                    .iter()
                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n"),
                _ => String::new(),
            };
            text.lines().any(|l| l.trim() == id)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doing_and_said_come_from_the_sessions_own_turns() {
        let text = [
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"first  note"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -H secret","description":"Fetch  the page"}}]}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"},{"type":"tool_use","name":"Read","input":{}}]}}"#,
        ]
        .join("\n");
        assert_eq!(
            doing_said(&text),
            ("Bash: Fetch the page".to_string(), "first note".to_string())
        );
        // No description: the tool's name alone, and the command is never copied.
        let bare = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -H secret"}}]}}"#;
        assert_eq!(doing_said(bare), ("Bash".to_string(), String::new()));
    }

    #[test]
    fn said_around_is_the_turn_that_printed_the_ask_id() {
        let lines = [
            r#"{"type":"user","message":{"content":"earlier ask"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"not this turn"}]}}"#,
            r#"{"type":"user","message":{"content":"should we keep the merge queue"}}"#,
            r#"{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued"}}"#,
            r#"{"type":"user","message":{"content":"This session was moved from the main Claude account to alt"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looked at the queue."},{"type":"tool_use","id":"b1","name":"Bash","input":{}}]}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"a subagent's words"}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"asking you\nAbC123"}]}}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"a reminder"}}"#,
            r#"{"type":"user","message":{"content":"<task-notification> done"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Keep it? 1 keep 2 drop"}]}}"#,
            r#"{"type":"user","message":{"content":"1"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"after the answer"}]}}"#,
        ];
        let got = said_around(&lines.join("\n"), "AbC123").unwrap();
        let slash = r#"{"type":"user","message":{"content":"<command-message>go</command-message>\n<command-name>/my:go</command-name>\n<command-args>ship it</command-args>"}}"#;
        assert_eq!(typed_prompt(slash).as_deref(), Some("/my:go ship it"));
        assert_eq!(got.first, "earlier ask");
        assert_eq!(got.prompt, "should we keep the merge queue");
        assert_eq!(got.said, ["Looked at the queue.", "Keep it? 1 keep 2 drop"]);
        // Negative controls: an id only mentioned in passing, or never printed, finds nothing.
        assert_eq!(said_around(&lines.join("\n"), "AbC12"), None);
        assert_eq!(said_around(&lines.join("\n"), "zzz999"), None);
        assert_eq!(said_around(&lines.join("\n"), ""), None);
    }
}
