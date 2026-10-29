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
    /// The session's last word asks the human something: see `asks_human`. Whether it is
    /// still waiting on the answer also needs the session status, which the caller holds.
    pub question: bool,
}

pub fn row_info(path: &Path) -> RowInfo {
    let text = read(path);
    RowInfo {
        summary: last_event_in(&text),
        plan: permission_mode(&text).as_deref() == Some("plan"),
        question: asks_human(&text),
    }
}

/// The session ended its turn by asking the human something, in its own conversation rather
/// than through `agent-ask`. True when the last main-thread entry is the assistant's (no prompt
/// or tool result after it) and either its last call is a dialog tool left open
/// (AskUserQuestion, ExitPlanMode) or its closing text asks a question (`text_asks`).
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
        Some("text") => text_asks(block.get("text").and_then(Value::as_str).unwrap_or("")),
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
}

pub fn fleet_info(path: &Path) -> FleetInfo {
    let text = read(path);
    let (context_tokens, model) = last_usage(&text);
    FleetInfo {
        context_tokens,
        model,
        plan_file: plan_file(&text),
        last_entry: last_entry(&text),
        edited_files: edited_files(&text),
    }
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
        assert!(row_info(&p).question);
        fs::remove_file(&p).ok();
        assert!(!row_info(Path::new("/no/such/file.jsonl")).question);
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
