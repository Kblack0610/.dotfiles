//! Tail a Claude transcript JSONL: a one-line summary for the chooser row and
//! the last few events for the preview pane.

use std::fs;
use std::path::Path;

use serde_json::Value;

/// Collapse runs of whitespace to single spaces and trim.
fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Truncate to `n` characters (char-safe, never splits a multibyte char).
fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// The last `n` lines of a transcript's text.
fn tail_lines(text: &str, n: usize) -> Vec<&str> {
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].to_vec()
}

/// Parse JSONL lines, keeping only assistant/user events in order.
fn turns(text: &str) -> Vec<Value> {
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
fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// What a chooser row needs from the transcript, from a single read of it.
pub struct RowInfo {
    /// One-line summary of the most recent turn.
    pub summary: String,
    /// The session is in plan mode.
    pub plan: bool,
}

pub fn row_info(path: &Path) -> RowInfo {
    let text = read(path);
    RowInfo {
        summary: last_event_in(&text),
        plan: permission_mode(&text).as_deref() == Some("plan"),
    }
}

/// The transcript at `path` ends on the session asking the human something: `asks_human`.
/// The Stop check (`stop-post.d/88-ask-filed.sh`) reads it through `agent-panel asks-human`
/// to make the session file that ask; no view reads it, the ask file is the record.
pub fn asks_human_at(path: &Path) -> bool {
    asks_human(&read(path))
}

/// The session ended its turn by asking the human something in its own conversation. True when
/// the last main-thread entry is the assistant's (no prompt or tool result after it) and either
/// its last call is a dialog tool left open (AskUserQuestion, ExitPlanMode), or its closing text
/// asks a question (`text_asks`) or asks the human to do something (`text_requests_action`).
fn asks_human(text: &str) -> bool {
    // The human's side: a typed prompt or a tool result, not a reminder or a subagent's.
    let answer = |v: &Value| {
        v.get("type").and_then(Value::as_str) == Some("user")
            && v.get("isMeta").and_then(Value::as_bool) != Some(true)
            && v.get("isSidechain").and_then(Value::as_bool) != Some(true)
    };
    let last = text
        .lines()
        .rev()
        .filter(|l| l.contains("\"type\":\"assistant\"") || l.contains("\"type\":\"user\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| own_turn(v) || answer(v))
        .filter(own_turn);
    let Some(block) = last.as_ref().and_then(|v| v.pointer("/message/content")?.as_array()?.last()) else {
        return false;
    };
    match block.get("type").and_then(Value::as_str) {
        Some("tool_use") => matches!(block.get("name").and_then(Value::as_str), Some("AskUserQuestion" | "ExitPlanMode")),
        Some("text") => {
            let msg = block.get("text").and_then(Value::as_str).unwrap_or("");
            text_asks(msg) || text_requests_action(msg)
        }
        _ => false,
    }
}

/// An entry the session wrote itself: a main-thread assistant turn, not a subagent's.
fn own_turn(v: &Value) -> bool {
    v.get("type").and_then(Value::as_str) == Some("assistant")
        && v.get("isSidechain").and_then(Value::as_bool) != Some(true)
}

/// Closing questions that are manners, not asks: a session that ends every turn this way is not
/// waiting on anything. Matched against the start of the lowercased sentence.
const GENERIC_CLOSERS: [&str; 5] = ["anything else", "is there anything else", "any questions", "any other questions", "what's next"];

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
    let asks = |found: Vec<String>| found.iter().any(|s| !GENERIC_CLOSERS.iter().any(|g| s.starts_with(g)));
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
const ACTION_CUES: [&str; 6] = ["when that's done", "once that's done", "when you've", "once you've", "let me know when", "once you have"];

/// The message ends by asking the human to act rather than asking a question: one of its last
/// two blocks is a fenced `! <command>` line (only the human's prompt runs those), or its closing
/// prose paragraph carries an `ACTION_CUES` phrase. 2026-10-28 a session ended on a `! ssh ...`
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
    let command = tail.iter().any(|(f, b)| *f && b.iter().any(|l| l.trim_start().starts_with("! ")));
    let cue = tail.last().is_some_and(|(f, b)| {
        let p = b.join(" ").to_lowercase().replace('\u{2019}', "'");
        !*f && ACTION_CUES.iter().any(|c| p.contains(c))
    });
    command || cue
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
        let item = ["- ", "* ", "+ "].iter().find_map(|m| t.strip_prefix(m)).or_else(|| {
            (numbered.len() < t.len()).then(|| numbered.strip_prefix(". ").or_else(|| numbered.strip_prefix(") "))).flatten()
        });
        let chars: Vec<char> = item.unwrap_or(t).chars().collect();
        let (mut code, mut quote, mut start) = (false, false, 0);
        // Punctuation ends a sentence when only closing markdown sits between it and a space.
        let closing = |c: &&char| !matches!(c, '*' | '_' | ')');
        let ends = |i: usize| chars[i + 1..].iter().find(closing).is_none_or(|n| n.is_whitespace());
        let ends_line = |i: usize| chars[i + 1..].iter().filter(closing).all(|c| c.is_whitespace());
        for (i, &c) in chars.iter().enumerate() {
            match c {
                '`' => code = !code,
                '"' if !code => quote = !quote,
                '\u{201c}' if !code => quote = true,
                '\u{201d}' if !code => quote = false,
                '.' | '!' | ':' | '?' if !code && !quote && ends(i) => {
                    let from = std::mem::replace(&mut start, i + 1);
                    if c == '?' && (item.is_none() || ends_line(i)) {
                        let s: String = chars[from..i].iter().filter(|c| !matches!(c, '*' | '_' | '#')).collect();
                        out.push(s.trim().to_lowercase());
                    }
                }
                _ => {}
            }
        }
    }
    out
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
    /// Absolute paths the session changed through Edit, Write, MultiEdit or NotebookEdit,
    /// in first-edit order. fleet-sessions counts only these as its dirt in a shared checkout.
    pub edited_files: Vec<String>,
    pub time_use: TimeUse,
    /// The last main-thread tool call, `<Tool>: <description>`, empty when there is none.
    pub doing: String,
    /// The last main-thread assistant text on one line, clipped to `SAID_CHARS`.
    pub said: String,
    /// How many times the context was compacted.
    pub compactions: u64,
}

pub fn fleet_info(path: &Path) -> FleetInfo {
    let text = read(path);
    let (context_tokens, model) = last_usage(&text);
    let (doing, said) = doing_said(&text);
    FleetInfo {
        context_tokens,
        model,
        plan_file: plan_file(&text),
        last_entry: last_entry(&text),
        edited_files: edited_files(&text),
        time_use: time_use(&text, &job_patterns(&time_use_conf())),
        doing,
        said,
        compactions: compactions(&text),
    }
}

/// A gap between entries shorter than this is the session working; a longer one was a wait,
/// and what was still running says for what.
const WORK_GAP_SECS: u64 = 300;
/// How far past a gap's end to look for the entry that says who ended it.
const WAKE_SECS: u64 = 60;
/// A job open longer than this is taken as gone: a session can die with no record of it. The
/// longest real ones run about 5 hours (p99, 1782 background commands, 2026-10-30).
const JOB_MAX_SECS: u64 = 12 * 3600;
/// In the notification a resumed session gets for each job that died with the old process.
const SESSION_ENDED: &str = "before the previous session ended";
/// `toolUseResult` fields that mean the call went on in the background under that id.
const BACKGROUND_IDS: [&str; 4] = ["backgroundTaskId", "taskId", "resumedAgentId", "revivedAgentId"];
/// Which commands are a merge gate or a test run. Content, so it lives in dotfiles config.
const TIME_USE_CONF: &str = ".config/agent-panel/time-use.conf";
const SAID_CHARS: usize = 120;
const HUMAN_TOOLS: [&str; 2] = ["AskUserQuestion", "ExitPlanMode"];

/// Minutes of a session's closed gaps, by what it was waiting on. The open gap since the last
/// entry is not here: IDLE already shows it, and what ends it is not known yet.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub struct TimeUse {
    pub work_min: u64,
    /// A job whose command `time-use.conf` calls a merge gate was running.
    pub gate_min: u64,
    /// A job whose command `time-use.conf` calls a test run was running.
    pub test_min: u64,
    /// Any other background job or foreground tool was running.
    pub jobs_min: u64,
    /// An AskUserQuestion or ExitPlanMode was open, or nothing was running and a prompt was typed.
    pub human_min: u64,
    /// Nothing was running: a peer's message or some other record woke it.
    pub parked_min: u64,
}

#[derive(Clone, Copy, PartialEq)]
enum Wait {
    Work,
    Gate,
    Test,
    Jobs,
    Human,
    Parked,
}

/// A tool call still running. Holds what it counts as, never its command, which can hold a secret.
struct Job {
    tool_id: String,
    task_id: Option<String>,
    wait: Wait,
    since: u64,
}

/// `<gate|test> <text in the command>` lines. The first line that matches wins.
fn job_patterns(conf: &str) -> Vec<(Wait, &str)> {
    conf.lines()
        .filter_map(|l| {
            let (kind, text) = l.trim().split_once(char::is_whitespace)?;
            match kind {
                "gate" => Some((Wait::Gate, text.trim())),
                "test" => Some((Wait::Test, text.trim())),
                _ => None,
            }
        })
        .collect()
}

/// With no config every job counts as `jobs`, which is still true.
fn time_use_conf() -> String {
    fs::read_to_string(crate::session::home().join(TIME_USE_CONF)).unwrap_or_default()
}

pub fn time_use_at(path: &Path) -> TimeUse {
    time_use(&read(path), &job_patterns(&time_use_conf()))
}

/// Split the transcript's elapsed time. Reads every line, so it stays on substring checks and
/// parses only lines that start or end a job, and around a long gap. The first `"timestamp":"`
/// on a line is the entry's own (escaped copies inside a string do not match); a
/// file-history-snapshot has only a nested one. The running max keeps a burst written out of
/// order from reading as a gap. A gap is counted before its last line can end a job.
fn time_use(text: &str, patterns: &[(Wait, &str)]) -> TimeUse {
    let lines: Vec<&str> = text.lines().filter(|l| !skipped_entry(l)).collect();
    let mut secs = [0u64; 6];
    let mut last: Option<u64> = None;
    let mut jobs: Vec<Job> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let at = entry_epoch(line);
        if let (Some(at), Some(prev)) = (at, last) {
            if at > prev {
                let gap = at - prev;
                let wait = if gap < WORK_GAP_SECS { Wait::Work } else { gap_wait(&lines[i..], prev, at, &mut jobs) };
                secs[wait as usize] += gap;
            }
        }
        last = last.max(at);
        track_jobs(line, last.unwrap_or(0), patterns, &mut jobs);
    }
    let [work, gate, test, jobs, human, parked] = secs.map(|s| s / 60);
    TimeUse { work_min: work, gate_min: gate, test_min: test, jobs_min: jobs, human_min: human, parked_min: parked }
}

/// A subagent's entry, or a snapshot whose only timestamp is nested.
fn skipped_entry(line: &str) -> bool {
    line.contains("\"isSidechain\":true") || line.starts_with("{\"type\":\"file-history-snapshot\"")
}

fn entry_epoch(line: &str) -> Option<u64> {
    const KEY: &str = "\"timestamp\":\"";
    line.find(KEY)
        .and_then(|i| line.get(i + KEY.len()..))
        .and_then(|rest| rest.split('"').next())
        .and_then(iso_epoch)
}

/// Keep the open jobs current with one entry.
fn track_jobs(line: &str, at: u64, patterns: &[(Wait, &str)], jobs: &mut Vec<Job>) {
    if !["\"tool_use\"", "\"tool_result\"", "<task-notification>"].iter().any(|k| line.contains(k)) {
        return;
    }
    let Ok(v) = serde_json::from_str::<Value>(line) else { return };
    match v.get("type").and_then(Value::as_str) {
        Some("assistant") => {
            for c in content_blocks(&v) {
                if c.get("type").and_then(Value::as_str) == Some("tool_use") {
                    open_job(c, at, patterns, jobs);
                }
            }
        }
        Some("user") => {
            if let Some(s) = v.pointer("/message/content").and_then(Value::as_str) {
                close_notified(s, jobs);
            }
            for c in content_blocks(&v) {
                match c.get("type").and_then(Value::as_str) {
                    Some("tool_result") => tool_returned(&v, c, jobs),
                    Some("text") => close_notified(c.get("text").and_then(Value::as_str).unwrap_or(""), jobs),
                    _ => {}
                }
            }
        }
        Some("queue-operation") => close_notified(v.get("content").and_then(Value::as_str).unwrap_or(""), jobs),
        _ => {}
    }
}

fn content_blocks(v: &Value) -> &[Value] {
    v.pointer("/message/content").and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn open_job(call: &Value, at: u64, patterns: &[(Wait, &str)], jobs: &mut Vec<Job>) {
    let name = call.get("name").and_then(Value::as_str).unwrap_or("");
    let input = call.get("input");
    if name == "TaskStop" {
        let id = input.and_then(|i| i.get("task_id")).and_then(Value::as_str);
        jobs.retain(|j| j.task_id.is_none() || j.task_id.as_deref() != id);
    }
    let command = input.and_then(|i| i.get("command")).and_then(Value::as_str).unwrap_or("");
    let wait = if HUMAN_TOOLS.contains(&name) {
        Wait::Human
    } else {
        patterns.iter().find(|(_, text)| command.contains(text)).map_or(Wait::Jobs, |(wait, _)| *wait)
    };
    if let Some(id) = call.get("id").and_then(Value::as_str) {
        jobs.push(Job { tool_id: id.to_string(), task_id: None, wait, since: at });
    }
}

/// A call's result ends it, unless the result says it went on in the background.
fn tool_returned(entry: &Value, block: &Value, jobs: &mut Vec<Job>) {
    let id = block.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
    match background_id(entry) {
        Some(task) => {
            if let Some(job) = jobs.iter_mut().find(|j| j.tool_id == id) {
                job.task_id = Some(task.to_string());
            }
        }
        None => jobs.retain(|j| j.tool_id != id),
    }
}

/// An Agent call reports its id whether or not it waits, so only `isAsync` counts there.
fn background_id(entry: &Value) -> Option<&str> {
    let result = entry.get("toolUseResult")?;
    let id = |key: &str| result.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
    BACKGROUND_IDS.iter().find_map(|k| id(k)).or_else(|| {
        (result.get("isAsync").and_then(Value::as_bool) == Some(true)).then(|| id("agentId")).flatten()
    })
}

/// A job's notification ends it. A Monitor's event only reports, and its watch stays open: a
/// status or the watch expiring is what ends one.
fn close_notified(s: &str, jobs: &mut Vec<Job>) {
    if !s.starts_with("<task-notification>") || !(s.contains("<status>") || s.contains("Monitor expired")) {
        return;
    }
    let (tool, task) = (tag_text(s, "tool-use-id"), tag_text(s, "task-id"));
    jobs.retain(|j| Some(j.tool_id.as_str()) != tool && (task.is_none() || j.task_id.as_deref() != task));
}

fn tag_text<'a>(s: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let rest = s.get(s.find(&open)? + open.len()..)?;
    rest.split('<').next()
}

/// What a long gap was waiting on. A slow model turn is the session working, and an open dialog
/// is you. Otherwise a running job counts, however the gap ended: a peer's message during a
/// gate is still a wait on the gate. With nothing running, what ended the gap says.
fn gap_wait(lines: &[&str], start: u64, end: u64, jobs: &mut Vec<Job>) -> Wait {
    let wake = gap_end(lines, end);
    if wake == Wait::Work {
        return wake;
    }
    // The process that ran them is gone, so nothing was running through this gap.
    if wake_window(lines, end).any(|l| l.contains(SESSION_ENDED)) {
        jobs.clear();
    }
    jobs.retain(|j| start.saturating_sub(j.since) < JOB_MAX_SECS);
    [Wait::Human, Wait::Gate, Wait::Test, Wait::Jobs]
        .into_iter()
        .find(|wait| jobs.iter().any(|j| j.wait == *wait))
        .unwrap_or(wake)
}

fn wake_window<'a>(lines: &'a [&'a str], end: u64) -> impl Iterator<Item = &'a &'a str> {
    lines.iter().take_while(move |l| entry_epoch(l).is_none_or(|at| at <= end + WAKE_SECS))
}

/// Who ended a long gap: the first entry at the gap's end that says who woke the session.
/// Bookkeeping lands around it, sometimes first: an `api-request` written just before the prompt
/// it sends, a `system` line for a mistyped command. Past WAKE_SECS those are all there is, and
/// nothing the session was running ended the gap.
fn gap_end(lines: &[&str], end: u64) -> Wait {
    for line in wake_window(lines, end) {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if let Some(wait) = entry_wait(&v) {
            return wait;
        }
    }
    Wait::Parked
}

/// Who an entry says woke the session, None for bookkeeping.
fn entry_wait(v: &Value) -> Option<Wait> {
    match v.get("type").and_then(Value::as_str)? {
        // A slow model turn is the session working: nothing arrived to end the gap.
        "assistant" => Some(Wait::Work),
        // An enqueue carries the prompt; its dequeue and remove carry nothing.
        "queue-operation" => v.get("content").and_then(Value::as_str).filter(|s| !s.is_empty()).map(prompt_wait),
        "user" if v.get("isMeta").and_then(Value::as_bool) == Some(true) => Some(Wait::Parked),
        "user" => match v.pointer("/message/content")? {
            Value::String(s) => Some(prompt_wait(s)),
            Value::Array(blocks) => {
                if blocks.iter().any(|c| c.get("type").and_then(Value::as_str) == Some("tool_result")) {
                    return Some(Wait::Jobs);
                }
                blocks
                    .iter()
                    .find(|c| c.get("type").and_then(Value::as_str) == Some("text"))
                    .map(|c| prompt_wait(c.get("text").and_then(Value::as_str).unwrap_or("")))
            }
            _ => None,
        },
        _ => None,
    }
}

/// Who a prompt came from, by its opening tag: the harness tags everything it injects.
fn prompt_wait(s: &str) -> Wait {
    if s.starts_with("<task-notification>") && !s.contains(SESSION_ENDED) {
        Wait::Jobs
    } else if !s.starts_with('<') || s.starts_with("<command") || s.starts_with("<local-command") {
        Wait::Human
    } else {
        Wait::Parked
    }
}

/// The last tool call and the last text of the session's own turns. Only a tool's description
/// is copied, never a Bash command, which can hold a secret.
fn doing_said(text: &str) -> (String, String) {
    let (mut doing, mut said) = (None, None);
    for line in text.lines().rev() {
        if doing.is_some() && said.is_some() {
            break;
        }
        if !line.contains("\"type\":\"assistant\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if !own_turn(&v) {
            continue;
        }
        let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else { continue };
        for c in blocks.iter().rev() {
            match c.get("type").and_then(Value::as_str) {
                Some("tool_use") if doing.is_none() => {
                    let name = c.get("name").and_then(Value::as_str).unwrap_or("?");
                    let desc = c.pointer("/input/description").and_then(Value::as_str).map(collapse).unwrap_or_default();
                    doing = Some(if desc.is_empty() { name.to_string() } else { format!("{name}: {}", truncate(&desc, SAID_CHARS)) });
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

fn compactions(text: &str) -> u64 {
    text.lines().filter(|l| l.contains("\"subtype\":\"compact_boundary\"") && !l.contains("\"isSidechain\":true")).count() as u64
}

/// The newest top-level `timestamp` among the last 200 lines. Entries written in one
/// burst land slightly out of order, so this is the max, not the last line's.
fn last_entry(text: &str) -> Option<u64> {
    tail_lines(text, 200)
        .iter()
        .filter(|l| l.contains("\"timestamp\":\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| v.get("timestamp").and_then(Value::as_str).and_then(iso_epoch))
        .max()
}

/// `2026-10-27T22:31:45.360Z` (UTC, optional fraction) -> epoch seconds. Anything else is None.
fn iso_epoch(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || !s.ends_with('Z') {
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

/// Files the session changed with its edit tools, deduplicated, in first-edit order.
fn edited_files(text: &str) -> Vec<String> {
    const TOOLS: [&str; 4] = ["Edit", "Write", "MultiEdit", "NotebookEdit"];
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for v in text
        .lines()
        .filter(|l| l.contains("\"tool_use\"") && TOOLS.iter().any(|t| l.contains(&format!("\"name\":\"{t}\""))))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v.get("type").and_then(Value::as_str) == Some("assistant"))
    {
        let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else { continue };
        for c in blocks {
            let name = c.get("name").and_then(Value::as_str).unwrap_or("");
            if c.get("type").and_then(Value::as_str) != Some("tool_use") || !TOOLS.contains(&name) {
                continue;
            }
            let input = c.get("input");
            let path = input
                .and_then(|i| i.get("file_path").or_else(|| i.get("notebook_path")))
                .and_then(Value::as_str);
            if let Some(p) = path.filter(|p| !p.is_empty()) {
                if seen.insert(p.to_string()) {
                    out.push(p.to_string());
                }
            }
        }
    }
    out
}

/// Token count and model of the last real assistant turn. Sidechain (subagent) turns
/// and `<synthetic>` placeholders carry their own, smaller contexts.
fn last_usage(text: &str) -> (u64, String) {
    text.lines()
        .rev()
        .filter(|l| l.contains("\"usage\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| {
            v.get("type").and_then(Value::as_str) == Some("assistant")
                && v.get("isSidechain").and_then(Value::as_bool) != Some(true)
                && v.pointer("/message/model").and_then(Value::as_str) != Some("<synthetic>")
        })
        .map(|v| {
            let n = |k: &str| v.pointer(&format!("/message/usage/{k}")).and_then(Value::as_u64).unwrap_or(0);
            let model = v.pointer("/message/model").and_then(Value::as_str).unwrap_or("");
            (
                n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens"),
                model.to_string(),
            )
        })
        .unwrap_or_default()
}

/// The plan file: the last `planFilePath` Claude recorded (plan mode writes it), else the
/// `~/.claude/plans/*.md` name the session's own turns (its text and tool calls) name most.
/// Nothing else in the transcript is the session's word: the SessionStart preflight (hook
/// attachments) lists other sessions' plans, and a prompt can be a pasted screen or a
/// shepherd nudge quoting another session's plan (2026-10-28, dotfiles-4c read as the
/// day-log plan). Only before the session's first reply does its prompt decide, since a
/// plan handed in by prompt is all a fresh session has; once it works the plan, it reads it.
fn plan_file(text: &str) -> String {
    const KEY: &str = "\"planFilePath\":\"";
    if let Some(i) = text.rfind(KEY) {
        let rest = &text[i + KEY.len()..];
        if let Some(end) = rest.find('"') {
            return rest[..end].to_string();
        }
    }
    const DIR: &str = "/.claude/plans/";
    const ASSISTANT: &str = "\"type\":\"assistant\"";
    let mut own: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut prompt = own.clone();
    let mut replied = false;
    for line in text.lines() {
        let named = line.contains(DIR);
        if !named && (replied || !line.contains(ASSISTANT)) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if own_turn(&v) {
            replied = true;
            if named {
                count_plans(&v.pointer("/message/content").map(Value::to_string).unwrap_or_default(), &mut own);
            }
        } else if named
            && v.get("type").and_then(Value::as_str) == Some("user")
            && v.get("isMeta").and_then(Value::as_bool) != Some(true)
        {
            // A typed prompt is a string; a tool result is an array, and is not the prompt.
            if let Some(s) = v.pointer("/message/content").and_then(Value::as_str) {
                count_plans(s, &mut prompt);
            }
        }
    }
    let counts = if replied { own } else { prompt };
    counts
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(&a.0)))
        .map(|(name, _)| crate::session::home().join(".claude/plans").join(name).to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Count each `~/.claude/plans/<name>.md` that `text` names into `counts`.
fn count_plans(text: &str, counts: &mut std::collections::HashMap<String, usize>) {
    const DIR: &str = "/.claude/plans/";
    for (i, _) in text.match_indices(DIR) {
        let rest = &text[i + DIR.len()..];
        let name_len = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')))
            .unwrap_or(rest.len());
        let name = &rest[..name_len];
        if name.ends_with(".md") && name.len() > 3 {
            *counts.entry(name.to_string()).or_default() += 1;
        }
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
                format!("tool: {}", c.get("name").and_then(Value::as_str).unwrap_or("?"))
            }
            Some("text") => format!(
                "say: {}",
                truncate(&collapse(c.get("text").and_then(Value::as_str).unwrap_or("")), 300)
            ),
            other => format!("asst: {}", other.unwrap_or("?")),
        }
    } else {
        "user: input".to_string()
    }
}

/// The last few turns formatted (most-recent first) for the preview pane.
pub fn recent_events(path: &Path, count: usize) -> Vec<String> {
    let all = turns(&read(path));
    all.iter()
        .rev()
        .take(count)
        .map(format_event)
        .collect()
}

fn format_event(v: &Value) -> String {
    if v.get("type").and_then(Value::as_str) == Some("assistant") {
        match v.pointer("/message/content/0") {
            Some(c) => match c.get("type").and_then(Value::as_str) {
                Some("tool_use") => {
                    let name = c.get("name").and_then(Value::as_str).unwrap_or("?");
                    let input = c
                        .get("input")
                        .map(|i| collapse(&i.to_string()))
                        .unwrap_or_default();
                    format!("  \x1b[33m⚙\x1b[0m {name} \x1b[2m{}\x1b[0m", truncate(&input, 160))
                }
                Some("text") => {
                    let t = collapse(c.get("text").and_then(Value::as_str).unwrap_or(""));
                    format!("  \x1b[32m▸\x1b[0m {}", truncate(&t, 500))
                }
                other => format!("  ? {}", other.unwrap_or("?")),
            },
            None => "  ? ".to_string(),
        }
    } else {
        let content = v.pointer("/message/content").map(value_text).unwrap_or_default();
        format!("  \x1b[36m◂\x1b[0m {}", truncate(&collapse(&content), 500))
    }
}

/// User message content is sometimes a string, sometimes an array of blocks.
fn value_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn tmpfile(tag: &str, lines: &[&str]) -> std::path::PathBuf {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("agent-panel-test-{}-{tag}.jsonl", std::process::id()));
        let mut f = fs::File::create(&path).unwrap();
        writeln!(f, "{}", lines.join("\n")).unwrap();
        path
    }

    /// An entry at `min` minutes past 12:00, with the rest of its JSON from `body`.
    fn at(min: u64, body: &str) -> String {
        let hour = 12 + min / 60;
        format!(r#"{{{body},"timestamp":"2026-10-{}T{:02}:{:02}:00.000Z"}}"#, 30 + hour / 24, hour % 24, min % 60)
    }

    #[test]
    fn time_use_buckets_a_gap_by_what_ended_it() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            at(2, r#""type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{}}]}"#),
            // A foreground tool and a task notification: jobs, 10 + 20.
            at(12, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"ok"}]}"#),
            at(32, r#""type":"queue-operation","operation":"enqueue","content":"<task-notification> done""#),
            at(32, r#""type":"assistant","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}"#),
            // AskUserQuestion's answer and a typed prompt: human, 30 + 40.
            at(62, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"a"}]}"#),
            at(102, r#""type":"user","message":{"content":"next"}"#),
            // A peer's message and a system record: parked, 50 + 60.
            at(152, r#""type":"queue-operation","operation":"enqueue","content":"<cross-session-message from=\"x\"> Shepherd""#),
            at(212, r#""type":"system","subtype":"informational""#),
            // A long model turn is work, 7; a typed prompt queued while busy is human, 8.
            at(219, r#""type":"assistant","message":{"content":[]}"#),
            at(227, r#""type":"queue-operation","operation":"enqueue","content":"also this""#),
        ];
        let text = lines.join("\n");
        assert_eq!(
            time_use(&text, &[]),
            TimeUse { work_min: 2 + 7, jobs_min: 30, human_min: 78, parked_min: 110, ..TimeUse::default() }
        );
    }

    #[test]
    fn time_use_ignores_sidechains_snapshots_and_out_of_order_lines() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            // A subagent's entry and a snapshot's nested timestamp must not split the gap.
            at(30, r#""type":"assistant","isSidechain":true,"message":{"content":[]}"#),
            r#"{"type":"file-history-snapshot","snapshot":{"timestamp":"2026-10-30T12:45:00.000Z"}}"#.to_string(),
            at(60, r#""type":"queue-operation","operation":"enqueue","content":"<task-notification>""#),
            // Written out of order: no negative gap, and the next gap runs from the max.
            at(59, r#""type":"assistant","message":{"content":[]}"#),
            at(61, r#""type":"assistant","message":{"content":[]}"#),
        ];
        assert_eq!(time_use(&lines.join("\n"), &[]), TimeUse { work_min: 1, jobs_min: 60, ..TimeUse::default() });
        assert_eq!(time_use("", &[]), TimeUse::default());
    }

    #[test]
    fn time_use_reads_past_bookkeeping_at_a_gaps_end() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            // An api-request written just ahead of the prompt it sends: human, 30.
            at(30, r#""type":"api-request""#),
            at(30, r#""type":"user","message":{"content":"back"}"#),
            // A mistyped command's system line, then the retry: human, 40.
            at(70, r#""type":"system","subtype":"informational","content":"Unknown command""#),
            at(70, r#""type":"user","message":{"content":"/compact"}"#),
            // A dequeue is bookkeeping too; the notification behind it is jobs, 50.
            at(120, r#""type":"queue-operation","operation":"dequeue""#),
            at(120, r#""type":"user","message":{"content":"<task-notification>x"}"#),
            // Bookkeeping with nothing real inside the window: parked, 60. The prompt 20
            // minutes later is its own gap: human, 20.
            at(180, r#""type":"pr-link""#),
            at(200, r#""type":"user","message":{"content":"late"}"#),
        ];
        assert_eq!(time_use(&lines.join("\n"), &[]), TimeUse { jobs_min: 50, human_min: 90, parked_min: 60, ..TimeUse::default() });
    }

    /// An assistant entry calling one tool, with the command already quoted for JSON.
    fn call(min: u64, id: &str, name: &str, input: &str) -> String {
        at(min, &format!(r#""type":"assistant","message":{{"content":[{{"type":"tool_use","id":"{id}","name":"{name}","input":{input}}}]}}"#))
    }

    /// The result of a call that went on in the background under `field`.
    fn launched(min: u64, id: &str, field: &str, task: &str) -> String {
        at(min, &format!(r#""type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"{id}","content":"started"}}]}},"toolUseResult":{{"{field}":"{task}"}}"#))
    }

    fn notified(min: u64, inner: &str) -> String {
        at(min, &format!(r#""type":"queue-operation","operation":"enqueue","content":"<task-notification> {inner}""#))
    }

    fn peer(min: u64) -> String {
        at(min, r#""type":"queue-operation","operation":"enqueue","content":"<cross-session-message from=\"x\"> hi""#)
    }

    const PATTERNS: [(Wait, &str); 2] = [(Wait::Gate, "ci-gate.sh"), (Wait::Test, "run.sh")];
    const GATE: &str = r#"{"command":"cd x && scripts/test/ci-gate.sh --pr 1","run_in_background":true}"#;
    const TEST: &str = r#"{"command":"scripts/test/run.sh Foo","run_in_background":true}"#;
    const OTHER: &str = r#"{"command":"sleep 1","run_in_background":true}"#;

    fn buckets(lines: &[String]) -> TimeUse {
        time_use(&lines.join("\n"), &PATTERNS)
    }

    #[test]
    fn time_use_counts_a_gap_by_the_job_still_running_whatever_ended_it() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            // A peer's message and a typed prompt during the gate: gate, 10 + 20.
            peer(10),
            at(30, r#""type":"user","message":{"content":"how is it"}"#),
            // Its own notification: gate, 30. Nothing is running after it.
            notified(60, "<tool-use-id>g</tool-use-id> <status>failed</status>"),
            // A peer's message with nothing running: parked, 40.
            peer(100),
        ]);
        assert_eq!(got, TimeUse { gate_min: 60, parked_min: 40, ..TimeUse::default() });
    }

    #[test]
    fn time_use_splits_gate_test_and_other_jobs_and_ranks_them() {
        let got = buckets(&[
            call(0, "o", "Bash", OTHER),
            launched(0, "o", "backgroundTaskId", "to"),
            // Other job alone: jobs, 10.
            peer(10),
            call(10, "t", "Bash", TEST),
            launched(10, "t", "backgroundTaskId", "tt"),
            // Test beside it: test, 20.
            peer(30),
            call(30, "g", "Bash", GATE),
            launched(30, "g", "backgroundTaskId", "tg"),
            // Gate beside both: gate, 40.
            notified(70, "<tool-use-id>g</tool-use-id> <status>completed</status>"),
            // Gate gone: test, 50.
            notified(120, "<tool-use-id>t</tool-use-id> <status>completed</status>"),
            // Test gone: jobs, 60.
            notified(180, "<tool-use-id>o</tool-use-id> <status>completed</status>"),
        ]);
        assert_eq!(got, TimeUse { gate_min: 40, test_min: 70, jobs_min: 70, ..TimeUse::default() });
    }

    #[test]
    fn time_use_an_open_dialog_is_you_even_with_a_gate_running() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            call(0, "q", "AskUserQuestion", "{}"),
            at(30, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q","content":"a"}]}"#),
            // The dialog is answered and the gate still runs: gate, 10.
            peer(40),
        ]);
        assert_eq!(got, TimeUse { gate_min: 10, human_min: 30, ..TimeUse::default() });
    }

    #[test]
    fn time_use_a_foreground_gate_counts_and_ends_with_its_result() {
        let got = buckets(&[
            call(0, "g", "Bash", r#"{"command":"scripts/test/ci-gate.sh"}"#),
            at(10, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g","content":"ok"}]}"#),
            peer(30),
        ]);
        assert_eq!(got, TimeUse { gate_min: 10, parked_min: 20, ..TimeUse::default() });
    }

    #[test]
    fn time_use_a_monitor_event_does_not_end_its_watch_but_an_expiry_does() {
        let got = buckets(&[
            call(0, "m", "Monitor", r#"{"command":"tail -f scripts/test/ci-gate.sh.log"}"#),
            launched(0, "m", "taskId", "tm"),
            // An event, by task id and with no status: the watch stays open, gate, 10 + 10.
            notified(10, r#"<task-id>tm</task-id> <summary>Monitor event: x</summary>"#),
            peer(20),
            // The expiry ends the gap as gate, 10, and ends the watch: parked, 10.
            notified(30, r#"<task-id>tm</task-id> <event>[Monitor expired after 30m]</event>"#),
            peer(40),
        ]);
        assert_eq!(got, TimeUse { gate_min: 30, parked_min: 10, ..TimeUse::default() });
    }

    #[test]
    fn time_use_a_task_stop_ends_the_job_it_names() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            peer(10),
            call(10, "t2", "Bash", TEST),
            launched(10, "t2", "backgroundTaskId", "tt"),
            call(10, "s", "TaskStop", r#"{"task_id":"tg"}"#),
            at(10, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s","content":"ok"}]},"toolUseResult":{"task_id":"tg"}"#),
            // The gate was stopped, the test still runs: test, 20.
            peer(30),
        ]);
        assert_eq!(got, TimeUse { gate_min: 10, test_min: 20, ..TimeUse::default() });
    }

    #[test]
    fn time_use_agents_run_in_the_background_only_when_the_result_says_so() {
        let got = buckets(&[
            call(0, "a", "Agent", r#"{"prompt":"look"}"#),
            at(0, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag"}"#),
            // By task id alone, the way a finished agent can report: jobs, 10, then parked, 10.
            notified(10, r#"<task-id>ag</task-id> <status>completed</status>"#),
            peer(20),
            call(20, "b", "Agent", r#"{"prompt":"look"}"#),
            // Waited for: the result ends it, jobs, 10, then parked, 10.
            at(30, r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"x"}]},"toolUseResult":{"status":"completed","agentId":"ag2"}"#),
            peer(40),
        ]);
        assert_eq!(got, TimeUse { jobs_min: 20, parked_min: 20, ..TimeUse::default() });
    }

    #[test]
    fn time_use_a_job_that_never_closes_stops_counting() {
        // Older than JOB_MAX_SECS when the last gap starts: parked, not gate.
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            peer(600),
            peer(730),
            peer(830),
        ]);
        assert_eq!(got, TimeUse { gate_min: 730, parked_min: 100, ..TimeUse::default() });
    }

    #[test]
    fn time_use_a_resume_means_the_jobs_died_with_the_old_process() {
        let ended = r#"<tool-use-id>g</tool-use-id> <status>stopped</status> <summary>Background shell command didn't finish before the previous session ended</summary>"#;
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            // The gate "ran" to the resume, by this record, but the session was gone: parked, 300.
            notified(300, ended),
            peer(310),
        ]);
        assert_eq!(got, TimeUse { parked_min: 310, ..TimeUse::default() });
    }

    #[test]
    fn the_shipped_time_use_conf_names_a_gate_and_a_test_and_reads_every_line() {
        let conf = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../.config/agent-panel/time-use.conf");
        let conf = fs::read_to_string(conf).unwrap();
        let patterns = job_patterns(&conf);
        let rows = conf.lines().filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#')).count();
        assert_eq!(patterns.len(), rows, "a line in time-use.conf is not `gate <text>` or `test <text>`");
        let kind = |command: &str| patterns.iter().find(|(_, t)| command.contains(t)).map(|(w, _)| *w);
        assert!(kind("scripts/test/ci-gate.sh --pr 1") == Some(Wait::Gate));
        assert!(kind("gh pr checks 12 --watch") == Some(Wait::Gate));
        assert!(kind("scripts/test/run.sh Foo") == Some(Wait::Test));
        assert!(kind("make -C tests test-fast") == Some(Wait::Test));
        assert!(kind("sleep 5").is_none());
    }

    #[test]
    fn doing_and_said_come_from_the_sessions_own_turns() {
        let text = [
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"first  note"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -H secret","description":"Fetch  the page"}}]}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"},{"type":"tool_use","name":"Read","input":{}}]}}"#,
        ]
        .join("\n");
        assert_eq!(doing_said(&text), ("Bash: Fetch the page".to_string(), "first note".to_string()));
        // No description: the tool's name alone, and the command is never copied.
        let bare = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -H secret"}}]}}"#;
        assert_eq!(doing_said(bare), ("Bash".to_string(), String::new()));
    }

    #[test]
    fn counts_main_thread_compactions() {
        let text = [
            r#"{"type":"system","subtype":"compact_boundary"}"#,
            r#"{"type":"system","subtype":"compact_boundary","isSidechain":true}"#,
            r#"{"type":"user","message":{"content":"the text \"subtype\":\"compact_boundary\" quoted"}}"#,
        ]
        .join("\n");
        assert_eq!(compactions(&text), 1);
    }

    #[test]
    fn summarizes_tool_use() {
        let p = tmpfile("tool", &[
            r#"{"type":"user","message":{"content":"hi"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
        ]);
        assert_eq!(last_event(&p), "tool: Bash");
        fs::remove_file(&p).ok();
    }

    #[test]
    fn summarizes_text_and_missing() {
        let p = tmpfile("text", &[r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello  world"}]}}"#]);
        assert_eq!(last_event(&p), "say: hello world");
        fs::remove_file(&p).ok();
        assert_eq!(last_event(Path::new("/no/such/file.jsonl")), "(no events)");
    }

    #[test]
    fn plan_mode_follows_the_last_mode_line() {
        let p = tmpfile("plan", &[
            r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
            r#"{"type":"user","permissionMode":"plan","message":{"content":"plan it"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
        ]);
        let info = row_info(&p);
        assert!(info.plan);
        assert_eq!(info.summary, "tool: Read");
        fs::remove_file(&p).ok();

        // Leaving plan mode (ExitPlanMode approved) writes a newer mode line.
        let p = tmpfile("built", &[
            r#"{"type":"permission-mode","permissionMode":"plan"}"#,
            r#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
        ]);
        assert!(!row_info(&p).plan);
        fs::remove_file(&p).ok();

        assert!(!row_info(Path::new("/no/such/file.jsonl")).plan);
    }

    #[test]
    fn fleet_info_reads_usage_and_plan() {
        let p = tmpfile("fleet", &[
            r#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":8}}}"#,
            r#"{"type":"attachment","attachment":{"planFilePath":"/h/.claude/plans/older.md"}}"#,
            r#"{"type":"attachment","attachment":{"planFilePath":"/h/.claude/plans/mine.md"}}"#,
            r#"{"type":"user","message":{"content":"see /h/.claude/plans/other.md and /h/.claude/plans/other.md"}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":5}}}"#,
            r#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}"#,
        ]);
        let info = fleet_info(&p);
        assert_eq!(info.context_tokens, 110);
        assert_eq!(info.model, "claude-opus-5-5");
        assert_eq!(info.plan_file, "/h/.claude/plans/mine.md");
        fs::remove_file(&p).ok();
    }

    #[test]
    fn last_entry_is_the_newest_timestamp_not_the_mtime() {
        let p = tmpfile("stamp", &[
            r#"{"type":"user","timestamp":"2026-10-27T22:31:45.505Z","message":{"content":"x"}}"#,
            r#"{"type":"api-request","timestamp":"2026-10-27T22:31:45.595Z"}"#,
            r#"{"type":"system","timestamp":"2026-10-27T22:31:45.403Z","content":"{\"timestamp\":\"2030-01-01T00:00:00Z\"}"}"#,
            r#"{"type":"last-prompt"}"#,
        ]);
        // 2026-10-27T22:31:45Z, cross-checked with `date -ud @1793140305`.
        assert_eq!(fleet_info(&p).last_entry, Some(1_793_140_305));
        fs::remove_file(&p).ok();
        assert_eq!(fleet_info(Path::new("/no/such/file.jsonl")).last_entry, None);
        assert_eq!(iso_epoch("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_epoch("2024-02-29T12:00:00.5Z"), Some(1_709_208_000));
        assert_eq!(iso_epoch("2026-10-27 22:31:45"), None);
    }

    #[test]
    fn edited_files_come_from_edit_tool_inputs_only() {
        let p = tmpfile("edits", &[
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/r/read-only.md"}}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Edit","input":{"file_path":"/r/a.rs","old_string":"","new_string":""}},{"type":"tool_use","name":"Write","input":{"file_path":"/r/b.md","content":""}}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/r/a.rs","edits":[]}}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/r/n.ipynb"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":""name":"Edit" "tool_use" /r/fake.md"}]}}"#,
        ]);
        assert_eq!(fleet_info(&p).edited_files, ["/r/a.rs", "/r/b.md", "/r/n.ipynb"]);
        fs::remove_file(&p).ok();
    }

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
        ] {
            assert!(asks_human(&said(msg)), "should ask: {msg}");
        }
        for msg in [
            // A `!` command early in an explanation, with more after it, is not the closing ask.
            "It ended on:\n\n```\n! ssh m1 true\n```\n\nThat is why it waited.\n\nThe check now catches it, and the PR is merged.",
            "When that's done is the wrong question here.\n\nMerged #604.",
            "```\n!important\n```",
        ] {
            assert!(!asks_human(&said(msg)), "should not ask: {msg}");
        }
    }

    #[test]
    fn only_the_last_main_thread_entry_decides() {
        let asked = said("Want me to land it?");
        // A dialog tool left open asks; any other last call is mid-turn.
        let tool = |name: &str| format!(r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"{name}"}}]}}}}"#);
        assert!(asks_human(&tool("AskUserQuestion")));
        assert!(asks_human(&tool("ExitPlanMode")));
        assert!(!asks_human(&tool("Bash")));
        // Answered: a prompt or a tool result after it.
        assert!(!asks_human(&format!("{asked}{}\n", r#"{"type":"user","message":{"content":"yes"}}"#)));
        assert!(!asks_human(&format!("{}\n{}\n", tool("AskUserQuestion"), r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"A"}]}}"#)));
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

    #[test]
    fn plan_file_falls_back_to_most_named() {
        let p = tmpfile("planref", &[
            r#"{"type":"user","message":{"content":"run ~/.claude/plans/a-b.md then /x/.claude/plans/a-b.md, not /x/.claude/plans/c.md"}}"#,
        ]);
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/a-b.md"));
        fs::remove_file(&p).ok();
        let none = fleet_info(Path::new("/no/such/file.jsonl"));
        assert_eq!((none.context_tokens, none.plan_file.as_str()), (0, ""));
    }

    #[test]
    fn plan_file_ignores_plans_only_the_preflight_and_others_name() {
        // The SessionStart preflight lists other sessions' plans in a hook attachment, a
        // reminder and a tool result echo them; the session's own Read is its plan.
        let preflight = r#"{"type":"attachment","attachment":{"type":"hook_additional_context","content":["Plans: ~/.claude/plans/theirs.md, ~/.claude/plans/theirs.md"]}}"#;
        let p = tmpfile("preflight", &[
            preflight,
            r#"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>~/.claude/plans/theirs.md</system-reminder>"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/h/.claude/plans/mine.md"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"see /h/.claude/plans/theirs.md"}]}}"#,
            r#"{"type":"api-request-blob","message":"~/.claude/plans/theirs.md ~/.claude/plans/theirs.md"}"#,
        ]);
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/mine.md"));
        fs::remove_file(&p).ok();

        // Named only there, the session has no plan of its own: not someone else's.
        let p = tmpfile("preflight-only", &[
            preflight,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}"#,
        ]);
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();

        // 2026-10-28, dotfiles-4c: a pasted screen quoting a shepherd nudge to another
        // session named its plan; once the session has replied without touching it, it is not its plan.
        let p = tmpfile("pasted", &[
            r#"{"type":"user","message":{"content":"Message from @other: every phase in /h/.claude/plans/theirs.md is ticked"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"checking the log"}]}}"#,
        ]);
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();
    }
}
