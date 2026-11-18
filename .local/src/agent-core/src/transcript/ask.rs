//! The open-question rule: whether the session ended its turn asking the human, and what it
//! asks. The Stop check, the panel, hub-core and agent-web all read it here.

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use super::read::{clip, own_turn, read, read_tail, str_of, tool_input};

/// The transcript at `path` ends on the session asking the human something: `asks_human`.
/// The Stop check (`stop-post.d/88-ask-filed.sh`) reads it through `agent-panel asks-human`
/// to make the session file that ask.
pub fn asks_human_at(path: &Path) -> bool {
    asks_human(&read_turn_end(path))
}

/// The session ended its turn by asking the human something in its own conversation: it has an
/// `open_question` that is not a permission prompt. A turn never ends on a call waiting for
/// permission, so at Stop that kind cannot be open.
fn asks_human(text: &str) -> bool {
    open_question(text).is_some_and(|q| q.kind != "tool")
}

/// What a session is asking the human, for a card.
#[derive(Debug, Serialize, PartialEq)]
pub struct Question {
    /// `choice` (an AskUserQuestion dialog, answered with its number key), `plan` (an
    /// ExitPlanMode dialog, its plan as the text), `tool` (a call waiting on permission) or
    /// `text` (a closing message that asks).
    pub kind: &'static str,
    pub text: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
}

/// `open_question` over the transcript at `path`. hub-core's NEEDS rows and agent-web's cards
/// read it for a waiting session.
pub fn open_question_at(path: &Path) -> Option<Question> {
    open_question(&read_turn_end(path))
}

/// The session's open question: the last main-thread entry is the assistant's (no prompt or
/// tool result after it, `last_turn_block`) and its last block is a dialog tool left open
/// (AskUserQuestion, ExitPlanMode), any other call (waiting on permission), or closing text that
/// asks a question (`text_asks`) or asks the human to do something (`text_requests_action`).
/// Closing text that does neither is a turn handed back, not a question.
fn open_question(text: &str) -> Option<Question> {
    let block = last_turn_block(text)?;
    let question = |kind, text: &str, options| Question {
        kind,
        text: clip(text),
        options,
    };
    match block.get("type").and_then(Value::as_str)? {
        "tool_use" => {
            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
            let input = block.get("input");
            Some(match name {
                "AskUserQuestion" => {
                    let first = input.and_then(|i| i.pointer("/questions/0"));
                    let options = first
                        .and_then(|q| q.get("options"))
                        .and_then(Value::as_array)
                        .map(|o| o.iter().map(|o| str_of(o.get("label"))).collect())
                        .unwrap_or_default();
                    question(
                        "choice",
                        &str_of(first.and_then(|q| q.get("question"))),
                        options,
                    )
                }
                "ExitPlanMode" => question(
                    "plan",
                    &str_of(input.and_then(|i| i.get("plan"))),
                    Vec::new(),
                ),
                _ => question(
                    "tool",
                    &format!("{name}: {}", tool_input(input)),
                    Vec::new(),
                ),
            })
        }
        "text" => {
            let msg = block.get("text").and_then(Value::as_str).unwrap_or("");
            (text_asks(msg) || text_requests_action(msg)).then(|| question("text", msg, Vec::new()))
        }
        _ => None,
    }
}

/// The dialog the session's turn ended on and still waits in: the open AskUserQuestion or
/// ExitPlanMode call's name and input (the questions with their options, or the plan text).
pub fn open_dialog_at(path: &Path) -> Option<(String, Value)> {
    open_dialog(&read_turn_end(path))
}

fn open_dialog(text: &str) -> Option<(String, Value)> {
    let block = last_turn_block(text)?;
    let name = block
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| HUMAN_TOOLS.contains(n))?;
    Some((
        name.to_string(),
        block.get("input").cloned().unwrap_or(Value::Null),
    ))
}

/// The last content block of the last main-thread entry, when that entry is the assistant's
/// own turn (no prompt or tool result after it).
fn last_turn_block(text: &str) -> Option<Value> {
    last_main_entry(text)
        .filter(own_turn)?
        .pointer("/message/content")?
        .as_array()?
        .last()
        .cloned()
}

/// The last main-thread entry: the session's own turn, or the human's side of it (a typed
/// prompt or a tool result, not a reminder or a subagent's).
fn last_main_entry(text: &str) -> Option<Value> {
    let answer = |v: &Value| {
        v.get("type").and_then(Value::as_str) == Some("user")
            && v.get("isMeta").and_then(Value::as_bool) != Some(true)
            && v.get("isSidechain").and_then(Value::as_bool) != Some(true)
    };
    text.lines()
        .rev()
        .filter(|l| l.contains("\"type\":\"assistant\"") || l.contains("\"type\":\"user\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| own_turn(v) || answer(v))
}

/// How much of a transcript's end the open-question readers take first. Transcripts grow to
/// tens of MB and hub-core and agent-web read every waiting session on each refresh.
const TURN_TAIL: u64 = 1024 * 1024;

/// Enough of the transcript at `path` to decide its open question: its last `TURN_TAIL` bytes
/// when they hold a main-thread entry, else the whole file, so the verdict is the whole
/// file's either way.
fn read_turn_end(path: &Path) -> String {
    let tail = read_tail(path, TURN_TAIL);
    if last_main_entry(&tail).is_some() {
        tail
    } else {
        read(path)
    }
}

/// Closing questions that are manners, not asks: a session that ends every turn this way is not
/// waiting on anything. Matched against the start of the lowercased sentence.
const GENERIC_CLOSERS: [&str; 5] = [
    "anything else",
    "is there anything else",
    "any questions",
    "any other questions",
    "what's next",
];

/// The message's closing paragraph asks a question, code fences dropped. A one-line paragraph
/// with no question after it (a "the screenshot is at X" postscript) does not hide the one before.
fn text_asks(msg: &str) -> bool {
    let mut fenced = false;
    let mut paras: Vec<Vec<&str>> = vec![Vec::new()];
    for line in msg.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
        } else if !fenced && line.trim().is_empty() {
            paras.push(Vec::new());
        } else if !fenced {
            paras.last_mut().expect("starts non-empty").push(line);
        }
    }
    paras.retain(|p| !p.is_empty());
    let asks = |found: Vec<String>| {
        found
            .iter()
            .any(|s| !GENERIC_CLOSERS.iter().any(|g| s.starts_with(g)))
    };
    let Some((last, before)) = paras.split_last() else {
        return false;
    };
    let found = question_sentences(last);
    match before.last() {
        Some(prev) if found.is_empty() && last.len() == 1 => asks(question_sentences(prev)),
        _ => asks(found),
    }
}

/// Phrases that hand the next step to the human ("when that's done, I'll re-run it"), matched in
/// the lowercased closing paragraph with curly apostrophes folded.
const ACTION_CUES: [&str; 7] = [
    "when that's done",
    "once that's done",
    "when you've",
    "once you've",
    "let me know when",
    "tell me when",
    "once you have",
];

/// Phrases in a prose block beside a fenced command that hand the command to the human. The
/// global rule forbids a leading `! ` in what a session writes, so a command the human must run
/// is a bare fence, and only these words tell it from a command the session quotes.
const HANDOFF_CUES: [&str; 7] = [
    "run this in your",
    "run these in your",
    "you can run",
    "please run",
    "paste this",
    "paste these",
    "paste it",
];

/// The message ends by asking the human to act rather than asking a question: one of its last
/// two blocks is a fenced `! <command>` line (only the human's prompt runs those), or is a fence
/// beside a prose block that hands it over (`HANDOFF_CUES`), or its closing prose paragraph
/// carries an `ACTION_CUES` phrase. 2026-10-28 a session ended on a `! ssh ...`
/// block and "When that's done, I'll re-run the job." with no `?`, and waited unflagged.
fn text_requests_action(msg: &str) -> bool {
    // Blocks: blank-line separated prose paragraphs, and each fence as one block of its own.
    let mut blocks: Vec<(bool, Vec<&str>)> = vec![(false, Vec::new())];
    let mut fenced = false;
    for line in msg.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
            blocks.push((fenced, Vec::new()));
        } else if !fenced && line.trim().is_empty() {
            blocks.push((false, Vec::new()));
        } else {
            blocks.last_mut().expect("starts non-empty").1.push(line);
        }
    }
    blocks.retain(|(_, b)| !b.is_empty());
    let tail = &blocks[blocks.len().saturating_sub(2)..];
    let command = tail
        .iter()
        .any(|(f, b)| *f && b.iter().any(|l| l.trim_start().starts_with("! ")));
    let prose = |b: &[&str]| b.join(" ").to_lowercase().replace('\u{2019}', "'");
    // The hand-off sentence may sit one paragraph before the fence it introduces.
    let near = &blocks[blocks.len().saturating_sub(3)..];
    let handed = tail.iter().any(|(f, _)| *f)
        && near
            .iter()
            .filter(|(f, _)| !*f)
            .map(|(_, b)| prose(b))
            .any(|p| HANDOFF_CUES.iter().any(|c| p.contains(c)));
    let cue = tail.last().is_some_and(|(f, b)| {
        let p = prose(b);
        !*f && ACTION_CUES.iter().any(|c| p.contains(c))
    });
    command || handed || cue
}

/// Each sentence in `lines` that ends in `?`, lowercased, with markdown emphasis stripped.
/// A `?` inside backticks or double quotes is quoted, not asked, and so is a `>` blockquote.
/// In a list item only a closing `?` counts: one with more text after it is a findings list
/// answering its own question ("2. Does X? Yes.").
fn question_sentences(lines: &[&str]) -> Vec<String> {
    let mut out = Vec::new();
    for line in lines {
        let t = line.trim();
        if t.starts_with('>') {
            continue;
        }
        let numbered = t.trim_start_matches(|c: char| c.is_ascii_digit());
        let item = ["- ", "* ", "+ "]
            .iter()
            .find_map(|m| t.strip_prefix(m))
            .or_else(|| {
                (numbered.len() < t.len())
                    .then(|| {
                        numbered
                            .strip_prefix(". ")
                            .or_else(|| numbered.strip_prefix(") "))
                    })
                    .flatten()
            });
        let chars: Vec<char> = item.unwrap_or(t).chars().collect();
        let (mut code, mut quote, mut start) = (false, false, 0);
        // Punctuation ends a sentence when only closing markdown sits between it and a space.
        let closing = |c: &&char| !matches!(c, '*' | '_' | ')');
        let ends = |i: usize| {
            chars[i + 1..]
                .iter()
                .find(closing)
                .is_none_or(|n| n.is_whitespace())
        };
        let ends_line = |i: usize| {
            chars[i + 1..]
                .iter()
                .filter(closing)
                .all(|c| c.is_whitespace())
        };
        for (i, &c) in chars.iter().enumerate() {
            match c {
                '`' => code = !code,
                '"' if !code => quote = !quote,
                '\u{201c}' if !code => quote = true,
                '\u{201d}' if !code => quote = false,
                '.' | '!' | ':' | '?' if !code && !quote && ends(i) => {
                    let from = std::mem::replace(&mut start, i + 1);
                    if c == '?' && (item.is_none() || ends_line(i)) {
                        let s: String = chars[from..i]
                            .iter()
                            .filter(|c| !matches!(c, '*' | '_' | '#'))
                            .collect();
                        out.push(s.trim().to_lowercase());
                    }
                }
                _ => {}
            }
        }
    }
    out
}

pub(super) const HUMAN_TOOLS: [&str; 2] = ["AskUserQuestion", "ExitPlanMode"];

/// The plan text of the open ExitPlanMode call, when the turn ended on one.
pub fn open_plan_at(path: &Path) -> Option<String> {
    open_plan(&read_turn_end(path))
}

fn open_plan(text: &str) -> Option<String> {
    let (_, input) = open_dialog(text).filter(|(n, _)| n == "ExitPlanMode")?;
    input.get("plan")?.as_str().map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_util::*;
    use std::fs;

    /// A transcript whose last main-thread entry is an assistant text block saying `msg`.
    fn said(msg: &str) -> String {
        let user = r#"{"type":"user","message":{"content":"go"}}"#;
        let asst = serde_json::json!({"type":"assistant","message":{"content":[{"type":"text","text":msg}]}});
        format!("{user}\n{asst}\n")
    }

    #[test]
    fn closing_questions_ask_the_human() {
        // Real closings from the 2026-10 transcript sample.
        for msg in [
            "Done.\n\nI haven't stopped anything. Want me to kill the scan or hold the fleet?",
            "Should I ask that session to add the line? Or just wind down now?",
            "Three causes:\n\n1. a\n2. b\n\nWhich of these are you seeing? If it's the cloud view, I can help with that.",
            "**My recommendation:** do HitReactions first. Should I start with HitReactions?**",
            // A one-line postscript does not hide the question before it.
            "**Decision for you:** Should I retire it or switch you to hypridle?\n\nI can publish the full report as a page if you want.",
            "Options:\n\n- Keep the hold?\n- Lift it now?",
        ] {
            assert!(asks_human(&said(msg)), "should ask: {msg}");
        }
    }

    #[test]
    fn statements_quotes_and_manners_do_not_ask() {
        for msg in [
            "Merged #599. The board row is closed.",
            "Anything else?",
            "All landed. Is there anything else you'd like me to look at?",
            // Quoted, in code, or a findings list answering its own question.
            r#"Questions asked: "With refusals piling up, is the slot pool growing?" Half answered."#,
            "Run `ls -d */?` to see them.",
            "> Why does it fail?\n\nBecause the pin moved.",
            "Findings:\n\n2. Does a headless `wt gc` see the same sessions? From this sweep, yes.\n3. Polling? Only the ps loop.",
            "```\nwhat?\n```",
            // A question earlier in the message is not the closing word.
            "Why did it fail?\n\nThe pin moved, so I re-pinned it and the gate is green.\nNothing is left open.",
            "",
        ] {
            assert!(!asks_human(&said(msg)), "should not ask: {msg}");
        }
    }

    #[test]
    fn handing_the_human_a_step_asks() {
        // agent-27, 2026-10-28: no `?`, and it waited on the human.
        let agent27 = "This step needs you. It's a terminal command, not a click, and you can run it from here (it will ask for the M1's password):\n\n```\n! ssh -t m1 'sudo mkdir -p \"/Library/Application Support/Unity\"'\n```\n\nWhen that's done, I'll re-run the job.";
        for msg in [
            agent27,
            "Run this in the prompt:\n\n```\n! gcloud auth login\n```",
            "The token is in rbw. Let me know when the secret is set and I'll re-run the deploy.",
            "Once you\u{2019}ve approved it on the phone I will merge.",
            // modernize-bar-ci-chip, 2026-11-17: a bare fence and "tell me when", no `?` and no `! `.
            "Ask qAlEej is cancelled, so run this in your terminal:\n\n```\nagent-ask answer qAlEej a\n```\n\nTell me when it is done and I will close the chip.",
            "Paste this into a shell:\n\n```\nrbw sync\n```",
            // The hand-off sentence alone, closing line carries no cue.
            "Run this in your terminal:\n\n```\nagent-ask answer qAlEej a\n```\n\nThen the chip closes.",
            "Please tell me when the key is in rbw.",
        ] {
            assert!(asks_human(&said(msg)), "should ask: {msg}");
        }
        for msg in [
            // A `!` command early in an explanation, with more after it, is not the closing ask.
            "It ended on:\n\n```\n! ssh m1 true\n```\n\nThat is why it waited.\n\nThe check now catches it, and the PR is merged.",
            "When that's done is the wrong question here.\n\nMerged #604.",
            "```\n!important\n```",
            // A command the session quotes, with no hand-off, is not a request.
            "I ran the gate:\n\n```\nbats tests/unit/x.bats\n```\n\n12 passed.",
            "The fix is in:\n\n```\nagent-land 2362\n```",
            "I pasted the failing output below:\n\n```\nFAILED x\n```",
            "I'll run this through the gate:\n\n```\nbats tests/unit/x.bats\n```",
        ] {
            assert!(!asks_human(&said(msg)), "should not ask: {msg}");
        }
    }

    const ASK: &str = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which key?","options":[{"label":"mint-key"},{"label":"stay-off"}]}]}}]}}"#;
    const ANSWERED: &str = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"mint-key"}]}}"#;

    #[test]
    fn the_readers_take_the_tail_and_the_whole_file_when_the_tail_has_no_turn() {
        // A subagent line is no main-thread entry, so 1.2 MB of them after the dialog push it
        // out of the tail and the whole file decides; a prompt after them decides from the tail.
        let side = format!(
            r#"{{"type":"user","isSidechain":true,"message":{{"content":"{}"}}}}"#,
            "x".repeat(1000)
        );
        let mut lines = vec![ASK];
        lines.extend(std::iter::repeat_n(side.as_str(), 1200));
        let p = tmpfile("turn-tail", &lines);
        assert_eq!(open_question_at(&p).map(|q| q.kind), Some("choice"));
        assert_eq!(
            open_dialog_at(&p).map(|(n, _)| n),
            Some("AskUserQuestion".into())
        );
        lines.push(r#"{"type":"user","message":{"content":"go"}}"#);
        let p = tmpfile("turn-tail", &lines);
        let tail = read_turn_end(&p);
        assert!(tail.len() < read(&p).len() && tail.starts_with('{'));
        assert_eq!(open_question_at(&p), None);
        fs::remove_file(&p).ok();
    }

    #[test]
    fn the_open_question_reads_the_open_dialog() {
        let q = open_question(&format!("{}{ASK}\n", said("Should I land it?"))).unwrap();
        assert_eq!(q.kind, "choice");
        assert_eq!(q.text, "Which key?");
        assert_eq!(q.options, ["mint-key", "stay-off"]);
    }

    #[test]
    fn the_open_question_is_gone_once_answered_and_reads_what_follows() {
        assert_eq!(open_question(&format!("{ASK}\n{ANSWERED}\n")), None);
        let asst = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Should I land it?"}]}}"#;
        let q = open_question(&format!("{ASK}\n{ANSWERED}\n{asst}\n")).unwrap();
        assert_eq!((q.kind, q.text.as_str()), ("text", "Should I land it?"));
        assert!(q.options.is_empty());
        let replied = format!(
            "{}{}\n",
            said("Should I land it?"),
            r#"{"type":"user","message":{"content":"yes"}}"#
        );
        assert_eq!(open_question(&replied), None);
        assert_eq!(
            open_question(r#"{"type":"user","message":{"content":"go"}}"#),
            None
        );
    }

    #[test]
    fn a_call_waiting_on_permission_is_a_tool_question_but_not_an_ask() {
        let tool = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push"}}]}}"#;
        let text = format!("{}{tool}\n", said("Should I land it?"));
        let q = open_question(&text).unwrap();
        assert_eq!((q.kind, q.text.as_str()), ("tool", "Bash: git push"));
        assert!(
            !asks_human(&text),
            "a Stop never ends on a call waiting for permission"
        );
    }

    #[test]
    fn an_open_plan_dialog_is_its_plan() {
        let tool = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"Hello\n1. write hello.txt"}}]}}"#;
        let q = open_question(&format!("{tool}\n")).unwrap();
        assert_eq!(
            (q.kind, q.text.as_str()),
            ("plan", "Hello\n1. write hello.txt")
        );
    }

    /// The one rule: closing text that hands the turn back without asking is no question, and a
    /// subagent's text is not the session's. hub-core read both as questions before ar-252.
    #[test]
    fn a_turn_handed_back_or_a_subagents_text_is_no_question() {
        assert_eq!(open_question(&said("Done. PR #12 merged.")), None);
        let side = r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"Want me to land it?"}]}}"#;
        assert_eq!(open_question(&format!("{}{side}\n", said("Merged."))), None);
    }

    #[test]
    fn the_open_dialog_carries_its_input_until_answered() {
        let plan = r##"{"type":"assistant","message":{"content":[{"type":"text","text":"Plan below."},{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"# Do it\nstep one"}}]}}"##;
        let (name, input) = open_dialog(&format!("{plan}\n")).unwrap();
        assert_eq!(name, "ExitPlanMode");
        assert_eq!(input["plan"], "# Do it\nstep one");
        // Answered, or another tool: no dialog.
        let answered =
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#;
        assert_eq!(open_dialog(&format!("{plan}\n{answered}\n")), None);
        assert_eq!(
            open_dialog(
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#
            ),
            None
        );
    }

    #[test]
    fn only_the_last_main_thread_entry_decides() {
        let asked = said("Want me to land it?");
        // A dialog tool left open asks; any other last call is mid-turn.
        let tool = |name: &str| {
            format!(
                r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"{name}"}}]}}}}"#
            )
        };
        assert!(asks_human(&tool("AskUserQuestion")));
        assert!(asks_human(&tool("ExitPlanMode")));
        assert!(!asks_human(&tool("Bash")));
        // Answered: a prompt or a tool result after it.
        assert!(!asks_human(&format!(
            "{asked}{}\n",
            r#"{"type":"user","message":{"content":"yes"}}"#
        )));
        assert!(!asks_human(&format!(
            "{}\n{}\n",
            tool("AskUserQuestion"),
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"A"}]}}"#
        )));
        // Reminders, subagent turns and bookkeeping entries after it do not answer it.
        let noise = [
            r#"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>x</system-reminder>"}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"done."}]}}"#,
            r#"{"type":"system","subtype":"stop_hook_summary"}"#,
            r#"{"type":"last-prompt"}"#,
        ];
        assert!(asks_human(&format!("{asked}{}\n", noise.join("\n"))));
        let p = tmpfile("asks", &[asked.trim_end()]);
        assert!(asks_human_at(&p));
        fs::remove_file(&p).ok();
        assert!(!asks_human_at(Path::new("/no/such/file.jsonl")));
    }
}
