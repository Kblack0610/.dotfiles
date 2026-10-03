//! Page through a Claude transcript JSONL by byte offset.
//!
//! Transcripts grow to tens of MB, so a page is read from the end backwards in
//! chunks and never loads the whole file. Offsets always sit on a line start, so a
//! client can ask for the page `before` the oldest line it holds, or for everything
//! `after` the newest one when the file grows.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde::Serialize;
use serde_json::Value;

const CHUNK: u64 = 256 * 1024;
/// A forward read larger than this means the client fell far behind; it gets the
/// newest page instead and starts over.
const MAX_FORWARD: u64 = 4 * 1024 * 1024;
const MAX_TEXT: usize = 4000;

#[derive(Debug, Serialize, PartialEq)]
pub struct Event {
    pub ts: String,
    /// `user` or `assistant`.
    pub role: &'static str,
    /// `text`, `tool_use` or `tool_result`.
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub text: String,
}

#[derive(Debug, Serialize)]
pub struct Page {
    pub events: Vec<Event>,
    /// Offset of the first line covered; 0 means the start of the transcript.
    pub start: u64,
    /// Offset just past the last complete line covered.
    pub end: u64,
}

/// Up to `limit` events ending at `before` (default: end of file).
pub fn page_before(path: &Path, before: Option<u64>, limit: usize) -> std::io::Result<Page> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let end = complete_end(&mut f, before.unwrap_or(len).min(len))?;

    let mut pos = end;
    let mut carry: Vec<u8> = Vec::new(); // unparsed bytes [pos, start)
    let mut start = end;
    let mut rev: Vec<Event> = Vec::new();

    while pos > 0 && rev.len() < limit {
        let n = CHUNK.min(pos);
        pos -= n;
        let mut chunk = vec![0u8; n as usize];
        f.seek(SeekFrom::Start(pos))?;
        f.read_exact(&mut chunk)?;
        chunk.extend_from_slice(&carry);
        carry = chunk;

        // Above the chunk boundary the first line is cut, so it waits for the next chunk.
        let split = if pos == 0 {
            0
        } else {
            match carry.iter().position(|&b| b == b'\n') {
                Some(i) => i + 1,
                None => continue,
            }
        };
        let complete = carry.split_off(split);
        let base = pos + split as u64;

        for (off, line) in lines_with_offsets(&complete).into_iter().rev() {
            let mut evs = parse_line(line);
            evs.reverse();
            rev.extend(evs);
            start = base + off as u64;
            if rev.len() >= limit {
                break;
            }
        }
        if rev.len() < limit {
            start = base;
        }
    }
    rev.reverse();
    Ok(Page {
        events: rev,
        start,
        end,
    })
}

/// Every event from `after` to the last complete line. Falls back to the newest
/// page when the gap is too large to send in one response.
pub fn page_after(path: &Path, after: u64, limit: usize) -> std::io::Result<Page> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    if after > len || len - after > MAX_FORWARD {
        return page_before(path, None, limit);
    }
    let mut buf = Vec::with_capacity((len - after) as usize);
    f.seek(SeekFrom::Start(after))?;
    f.take(len - after).read_to_end(&mut buf)?;
    let cut = buf
        .iter()
        .rposition(|&b| b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    buf.truncate(cut);
    let events = lines_with_offsets(&buf)
        .into_iter()
        .flat_map(|(_, l)| parse_line(l))
        .collect();
    Ok(Page {
        events,
        start: after,
        end: after + cut as u64,
    })
}

/// Pull `end` back to just after the last newline, so a line Claude is still
/// writing is never parsed half-done.
fn complete_end(f: &mut File, end: u64) -> std::io::Result<u64> {
    let mut pos = end;
    let mut buf = [0u8; 4096];
    while pos > 0 {
        let n = (buf.len() as u64).min(pos);
        f.seek(SeekFrom::Start(pos - n))?;
        f.read_exact(&mut buf[..n as usize])?;
        if let Some(i) = buf[..n as usize].iter().rposition(|&b| b == b'\n') {
            return Ok(pos - n + i as u64 + 1);
        }
        pos -= n;
    }
    Ok(0)
}

fn lines_with_offsets(buf: &[u8]) -> Vec<(usize, &[u8])> {
    let mut out = Vec::new();
    let mut off = 0;
    for line in buf.split(|&b| b == b'\n') {
        if !line.is_empty() {
            out.push((off, line));
        }
        off += line.len() + 1;
    }
    out
}

/// One JSONL line to zero or more display events. Meta lines (system reminders,
/// command echoes), thinking blocks and non-message records are dropped.
pub fn parse_line(line: &[u8]) -> Vec<Event> {
    let Ok(v) = serde_json::from_slice::<Value>(line) else {
        return Vec::new();
    };
    let role = match v.get("type").and_then(Value::as_str) {
        Some("user") => "user",
        Some("assistant") => "assistant",
        _ => return Vec::new(),
    };
    if v.get("isMeta").and_then(Value::as_bool) == Some(true) {
        return Vec::new();
    }
    let ts = v
        .get("timestamp")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let ev = |kind, name: Option<String>, text: String| Event {
        ts: ts.clone(),
        role,
        kind,
        name,
        text: clip(&text),
    };

    match v.pointer("/message/content") {
        Some(Value::String(s)) => vec![ev("text", None, s.clone())],
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| match b.get("type").and_then(Value::as_str)? {
                "text" => Some(ev("text", None, str_of(b.get("text")))),
                "tool_use" => Some(ev(
                    "tool_use",
                    b.get("name").and_then(Value::as_str).map(String::from),
                    tool_input(b.get("input")),
                )),
                "tool_result" => Some(ev("tool_result", None, result_text(b.get("content")))),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn str_of(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or("").to_string()
}

/// A tool call's input: the command or path when there is an obvious one, else the JSON.
fn tool_input(v: Option<&Value>) -> String {
    let Some(v) = v else { return String::new() };
    for key in [
        "command",
        "file_path",
        "pattern",
        "url",
        "prompt",
        "description",
    ] {
        if let Some(s) = v.get(key).and_then(Value::as_str) {
            return s.to_string();
        }
    }
    v.to_string()
}

/// Tool result content is a string or an array of `{type:text,text}` blocks.
fn result_text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|i| i.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

fn clip(s: &str) -> String {
    if s.chars().count() <= MAX_TEXT {
        return s.to_string();
    }
    let mut out: String = s.chars().take(MAX_TEXT).collect();
    out.push_str("\n[...]");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write(tag: &str, body: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("agent-web-{}-{tag}.jsonl", std::process::id()));
        File::create(&p)
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
        p
    }

    fn user(n: usize) -> String {
        format!("{{\"type\":\"user\",\"timestamp\":\"t{n}\",\"message\":{{\"content\":\"msg {n}\"}}}}\n")
    }

    #[test]
    fn parses_blocks_and_drops_noise() {
        let asst = br#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"hi"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}"#;
        let evs = parse_line(asst);
        assert_eq!(evs.len(), 2);
        assert_eq!((evs[0].kind, evs[0].text.as_str()), ("text", "hi"));
        assert_eq!(evs[1].name.as_deref(), Some("Bash"));
        assert_eq!(evs[1].text, "ls -la");

        let result = br#"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"ok"}]}]}}"#;
        assert_eq!(parse_line(result)[0].kind, "tool_result");
        assert_eq!(parse_line(result)[0].text, "ok");

        assert!(
            parse_line(br#"{"type":"user","isMeta":true,"message":{"content":"x"}}"#).is_empty()
        );
        assert!(parse_line(br#"{"type":"summary","summary":"x"}"#).is_empty());
        assert!(parse_line(b"not json").is_empty());
    }

    #[test]
    fn pages_backwards_without_gaps_or_overlap() {
        // Small lines but enough of them to cross several CHUNK boundaries.
        let body: String = (0..20000).map(user).collect();
        let p = write("pages", &body);

        let mut seen = Vec::new();
        let mut before = None;
        loop {
            let page = page_before(&p, before, 1000).unwrap();
            let mut texts: Vec<String> = page.events.into_iter().map(|e| e.text).collect();
            texts.append(&mut seen);
            seen = texts;
            if page.start == 0 {
                break;
            }
            before = Some(page.start);
        }
        assert_eq!(seen.len(), 20000);
        assert_eq!(seen[0], "msg 0");
        assert_eq!(seen[19999], "msg 19999");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn ignores_a_line_still_being_written_and_reads_forward() {
        let p = write(
            "partial",
            &format!("{}{}{{\"type\":\"user\",\"mess", user(1), user(2)),
        );
        let page = page_before(&p, None, 10).unwrap();
        assert_eq!(page.events.len(), 2);
        assert_eq!(page.end as usize, user(1).len() + user(2).len());

        let mut f = std::fs::OpenOptions::new().append(true).open(&p).unwrap();
        f.write_all(b"age\":{\"content\":\"msg 3\"}}\n").unwrap();
        let fwd = page_after(&p, page.end, 10).unwrap();
        assert_eq!(fwd.events.len(), 1);
        assert_eq!(fwd.events[0].text, "msg 3");
        assert_eq!(fwd.start, page.end);
        std::fs::remove_file(&p).ok();
    }
}
