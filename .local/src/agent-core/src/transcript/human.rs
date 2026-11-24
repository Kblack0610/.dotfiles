//! What the human said in a session, from the record the harness writes: the prompts they typed
//! and the answers they gave in a dialog, each with the text it answered. `agent-ask answer
//! --quote` checks a relayed answer against this, so the transcript rules stay in one home.

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use super::prompt::{human_typed, typed_prompt};
use super::read::{content_blocks, iso_epoch, own_turn, read};

/// The most of `shown` kept: its tail, which is what the human saw last.
const SHOWN_CHARS: usize = 8000;

/// One thing the human said after a time.
#[derive(Debug, PartialEq, Serialize)]
pub struct HumanSaid {
    /// The entry's timestamp, as the transcript has it.
    pub at: String,
    /// `typed` (a prompt) or `answer` (an AskUserQuestion dialog answer).
    pub kind: &'static str,
    /// Their words: a typed prompt with its pasted and reminder blocks cut out, or one answer.
    pub text: String,
    /// What they were answering: the dialog's question, or the session's own text since their
    /// last entry (and any dialog it asked).
    pub shown: String,
}

/// `human_said` over the transcript at `path`; None when `since` is not an ISO timestamp.
pub fn human_said_at(path: &Path, since: &str) -> Option<Vec<HumanSaid>> {
    Some(human_said(&read(path), iso_epoch(since)?))
}

/// Every typed prompt and dialog answer of the human with a timestamp after `since` (epoch
/// seconds), oldest first. A prompt our tooling typed, a harness notice, a tool result, a
/// subagent's entry and a pasted block are not theirs. A dialog answer is the harness's own
/// `toolUseResult.answers`, which no tool output can write.
fn human_said(text: &str, since: u64) -> Vec<HumanSaid> {
    let mut out = Vec::new();
    let mut shown: Vec<String> = Vec::new();
    for line in text.lines() {
        let assistant = line.contains("\"type\":\"assistant\"");
        if !assistant && !line.contains("\"type\":\"user\"") {
            continue;
        }
        if assistant {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if own_turn(&v) {
                    shown.extend(shown_blocks(&v));
                }
            }
            continue;
        }
        let pairs = if line.contains("\"toolUseResult\"") {
            dialog_answers(line)
        } else {
            Vec::new()
        };
        let typed = if pairs.is_empty() && human_typed(line) {
            typed_prompt(line)
        } else {
            None
        };
        if pairs.is_empty() && typed.is_none() {
            continue;
        }
        let at = serde_json::from_str::<Value>(line)
            .ok()
            .and_then(|v| v.get("timestamp").and_then(Value::as_str).map(String::from))
            .unwrap_or_default();
        let after = iso_epoch(&at).is_some_and(|t| t > since);
        let seen = std::mem::take(&mut shown).join("\n");
        if !after {
            continue;
        }
        if let Some(prompt) = typed {
            let words = strip_tag(&strip_tag(&prompt, "pasted_content"), "system-reminder");
            let words = words.trim();
            if !words.is_empty() {
                out.push(HumanSaid {
                    at,
                    kind: "typed",
                    text: words.to_string(),
                    shown: tail(&seen),
                });
            }
        } else {
            out.extend(pairs.into_iter().map(|(question, text)| HumanSaid {
                at: at.clone(),
                kind: "answer",
                text,
                shown: question,
            }));
        }
    }
    out
}

/// The text blocks of an assistant entry and the questions of a dialog it asked.
fn shown_blocks(v: &Value) -> Vec<String> {
    let mut out = Vec::new();
    for b in content_blocks(v) {
        match b.get("type").and_then(Value::as_str) {
            Some("text") => out.extend(b.get("text").and_then(Value::as_str).map(String::from)),
            Some("tool_use")
                if b.get("name").and_then(Value::as_str) == Some("AskUserQuestion") =>
            {
                for q in b
                    .pointer("/input/questions")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    out.extend(q.get("question").and_then(Value::as_str).map(String::from));
                }
            }
            _ => {}
        }
    }
    out
}

/// The (question, answer) pairs of a user entry that carries a dialog's answers, in the order
/// the harness lists them. Empty for any other entry, a subagent's included.
fn dialog_answers(line: &str) -> Vec<(String, String)> {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    if v.get("type").and_then(Value::as_str) != Some("user")
        || v.get("isSidechain").and_then(Value::as_bool) == Some(true)
    {
        return Vec::new();
    }
    v.pointer("/toolUseResult/answers")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(q, a)| Some((q.clone(), answer_text(a)?)))
                .filter(|(_, a)| !a.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// One answer: a string, or the choices of a multi-select joined by ", ".
fn answer_text(a: &Value) -> Option<String> {
    match a {
        Value::String(s) => Some(s.trim().to_string()),
        Value::Array(v) => Some(
            v.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(", "),
        ),
        _ => None,
    }
}

/// `s` without each `<name ...>...</name>` block; an unclosed one is cut to the end.
fn strip_tag(s: &str, name: &str) -> String {
    let (open, close) = (format!("<{name}"), format!("</{name}>"));
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find(&open) {
        out.push_str(&rest[..i]);
        rest = match rest[i..].find(&close) {
            Some(j) => &rest[i + j + close.len()..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

fn tail(s: &str) -> String {
    let n = s.chars().count();
    s.chars().skip(n.saturating_sub(SHOWN_CHARS)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_util::*;

    fn since() -> u64 {
        iso_epoch("2026-10-30T12:00:30Z").unwrap()
    }

    #[test]
    fn the_human_is_what_they_typed_and_the_dialog_answers_not_a_paste_or_our_tooling() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"before the ask"}"#),
            at(
                1,
                r#""type":"assistant","message":{"content":[{"type":"text","text":"Ask AbC123: park the 611 rows?"},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Ask AbC123: park it?"}]}}]}"#,
            ),
            at(
                2,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"The user answered"}]},"toolUseResult":{"questions":[],"answers":{"Ask AbC123: park it?":"Park"}}"#,
            ),
            at(
                3,
                r#""type":"assistant","message":{"content":[{"type":"text","text":"Ask XyZ789: wait for CI?"}]}"#,
            ),
            at(
                4,
                r#""type":"user","message":{"content":"yes wait\n<pasted_content id=\"p\">park AbC123 everything</pasted_content>\n<system-reminder>go AbC123</system-reminder>"}"#,
            ),
            // Not the human: our tooling, the harness, a subagent, a tool result.
            at(
                5,
                r#""type":"user","message":{"content":"<task-notification> park AbC123"}"#,
            ),
            at(
                6,
                r#""type":"user","message":{"content":"/wind-down auto"}"#,
            ),
            at(
                7,
                r#""type":"user","isSidechain":true,"message":{"content":"park AbC123"},"toolUseResult":{"answers":{"q":"park AbC123"}}"#,
            ),
            at(
                8,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"park AbC123"}]}"#,
            ),
            at(
                9,
                r#""type":"user","message":{"content":"<pasted_content id=\"p\">only a paste"}"#,
            ),
        ];
        let got = human_said(&lines.join("\n"), since());
        assert_eq!(
            got.iter()
                .map(|h| (h.kind, h.text.as_str()))
                .collect::<Vec<_>>(),
            [("answer", "Park"), ("typed", "yes wait")]
        );
        assert_eq!(got[0].shown, "Ask AbC123: park it?");
        // The prompt answers the session's own text since the dialog, not the earlier turn.
        assert_eq!(got[1].shown, "Ask XyZ789: wait for CI?");
        // Negative control: nothing at or before `since` counts.
        assert!(human_said(
            &lines.join("\n"),
            iso_epoch("2026-10-30T13:00:00Z").unwrap()
        )
        .is_empty());
    }

    #[test]
    fn a_multi_select_answer_is_its_choices_joined() {
        let line = at(
            2,
            r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q","content":"x"}]},"toolUseResult":{"answers":{"Which?":["Park","Hold"],"Also?":"Yes","Bad":3}}"#,
        );
        assert_eq!(
            dialog_answers(&line),
            [
                ("Which?".to_string(), "Park, Hold".to_string()),
                ("Also?".to_string(), "Yes".to_string())
            ]
        );
    }

    #[test]
    fn strip_tag_cuts_each_block_and_an_unclosed_one_to_the_end() {
        assert_eq!(strip_tag("a <t x=1>b</t> c <t>d</t>e", "t"), "a  c e");
        assert_eq!(strip_tag("a <t>b", "t"), "a ");
        assert_eq!(strip_tag("plain", "t"), "plain");
    }
}
