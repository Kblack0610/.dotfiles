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

/// Read the last `n` lines of a file. Returns empty on any read error.
fn tail_lines(path: &Path, n: usize) -> Vec<String> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// Parse JSONL lines, keeping only assistant/user events in order.
fn turns(path: &Path) -> Vec<Value> {
    tail_lines(path, 200)
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

/// One-line summary of the most recent turn, for the chooser row.
pub fn last_event(path: &Path) -> String {
    match turns(path).last() {
        None => "(no events)".to_string(),
        Some(v) => summarize(v),
    }
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
    let all = turns(path);
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
}
