//! Usage facts: context tokens and model, compactions, the newest entry, the files edited, and
//! the skills and models a session used.

use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use serde_json::Value;

use super::read::{iso_epoch, tail_lines};

pub(super) fn compactions(text: &str) -> u64 {
    text.lines()
        .filter(|l| {
            l.contains("\"subtype\":\"compact_boundary\"") && !l.contains("\"isSidechain\":true")
        })
        .count() as u64
}

/// The newest top-level `timestamp` among the last 200 lines. Entries written in one
/// burst land slightly out of order, so this is the max, not the last line's.
pub(super) fn last_entry(text: &str) -> Option<u64> {
    tail_lines(text, 200)
        .iter()
        .filter(|l| l.contains("\"timestamp\":\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            v.get("timestamp")
                .and_then(Value::as_str)
                .and_then(iso_epoch)
        })
        .max()
}

/// The Claude tools that write a file, one name a line: the one list, which the shell, jq and
/// Python readers read too.
const EDIT_TOOLS: &str = include_str!("../../../../../.config/agent-panel/edit-tools.conf");

/// [`EDIT_TOOLS`]' names, each with the `"name":"<tool>"` needle a transcript line carries.
fn edit_tools() -> &'static [(&'static str, String)] {
    static TOOLS: std::sync::OnceLock<Vec<(&'static str, String)>> = std::sync::OnceLock::new();
    TOOLS.get_or_init(|| {
        super::conf_lines(EDIT_TOOLS)
            .map(|t| (t, format!("\"name\":\"{t}\"")))
            .collect()
    })
}

/// Whether a tool_use `name` is one of [`EDIT_TOOLS`] (plan.rs reads the same list).
pub(super) fn is_edit_tool(name: &str) -> bool {
    edit_tools().iter().any(|(t, _)| *t == name)
}

/// Files the session changed with its edit tools, deduplicated, in first-edit order.
pub(super) fn edited_files(text: &str) -> Vec<String> {
    let tools = edit_tools();
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for v in text
        .lines()
        .filter(|l| {
            l.contains("\"tool_use\"")
                && tools.iter().any(|(_, needle)| l.contains(needle.as_str()))
        })
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v.get("type").and_then(Value::as_str) == Some("assistant"))
    {
        let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else {
            continue;
        };
        for c in blocks {
            let name = c.get("name").and_then(Value::as_str).unwrap_or("");
            if c.get("type").and_then(Value::as_str) != Some("tool_use")
                || !tools.iter().any(|(t, _)| *t == name)
            {
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
pub(super) fn last_usage(text: &str) -> (u64, String) {
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
            let n = |k: &str| {
                v.pointer(&format!("/message/usage/{k}"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
            };
            let model = v
                .pointer("/message/model")
                .and_then(Value::as_str)
                .unwrap_or("");
            (
                n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens"),
                model.to_string(),
            )
        })
        .unwrap_or_default()
}

/// The context window a session on `model` works in, None for a model this does not know (a
/// gateway lane, a Codex run). Every Claude model runs in Claude Code's 200k window, where it
/// auto-compacts near 167k: the API's 1M needs a `[1m]` model name, which no fleet launch uses and
/// which the transcript's model id would not show.
pub fn context_window(model: &str) -> Option<u64> {
    model.starts_with("claude-").then_some(200_000)
}

/// What a session used, counted from its transcript: each skill it called and each model that
/// answered, by name. A live session has no outcome row yet, so this is its only source.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Uses {
    pub skills: BTreeMap<String, u64>,
    pub models: BTreeMap<String, u64>,
}

/// Stream the whole file once, parsing only assistant lines. A streamed reply is written as one
/// line per content block, so a message id and a tool call id each count once. A line that is not
/// JSON is skipped.
pub fn uses(path: &Path) -> std::io::Result<Uses> {
    let meta = std::fs::metadata(path)?;
    let stamp = (meta.len(), meta.modified().ok());
    let mut kept = SCANNED.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((was, u)) = kept.get(path) {
        if *was == stamp {
            return Ok(u.clone());
        }
    }
    let u = scan(path)?;
    if kept.len() >= SCANNED_MAX {
        kept.clear();
    }
    kept.insert(path.to_path_buf(), (stamp, u.clone()));
    Ok(u)
}

/// The counts of the transcripts scanned, kept while a file's length and mtime hold: a page that
/// re-reads every few seconds does not stream an unchanged file again.
static SCANNED: Mutex<BTreeMap<PathBuf, (Stamp, Uses)>> = Mutex::new(BTreeMap::new());

/// A file as it was scanned: its length and mtime.
type Stamp = (u64, Option<SystemTime>);
const SCANNED_MAX: usize = 32;

fn scan(path: &Path) -> std::io::Result<Uses> {
    const ASSISTANT: &[u8] = br#""type":"assistant""#;
    let mut out = Uses::default();
    let (mut messages, mut calls) = (HashSet::new(), HashSet::new());
    for line in BufReader::new(File::open(path)?).split(b'\n') {
        let line = line?;
        if !line.windows(ASSISTANT.len()).any(|w| w == ASSISTANT) {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        if v["type"] != "assistant" {
            continue;
        }
        let m = &v["message"];
        if let Some(model) = m["model"].as_str().filter(|m| !m.starts_with('<')) {
            if fresh(&mut messages, &m["id"]) {
                *out.models.entry(model.to_string()).or_default() += 1;
            }
        }
        for b in m["content"].as_array().into_iter().flatten() {
            if b["type"] != "tool_use" || b["name"] != "Skill" {
                continue;
            }
            if let Some(skill) = b["input"]["skill"].as_str().filter(|s| !s.is_empty()) {
                if fresh(&mut calls, &b["id"]) {
                    *out.skills.entry(skill.to_string()).or_default() += 1;
                }
            }
        }
    }
    Ok(out)
}

/// True the first time `id` is seen; a block with no id always counts.
fn fresh(seen: &mut HashSet<String>, id: &Value) -> bool {
    id.as_str().is_none_or(|id| seen.insert(id.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::transcript::fleet_info;
    use crate::transcript::test_util::*;
    use std::fs;

    #[test]
    fn uses_counts_skill_calls_and_models_once_per_message() {
        let body = [
            r#"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"x"}]}}"#,
            r#"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"shepherd"}}]}}"#,
            r#"{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"shepherd"}},{"type":"tool_use","id":"t3","name":"Skill","input":{"skill":"debug"}},{"type":"tool_use","id":"t4","name":"Bash","input":{"skill":"no"}},{"type":"tool_use","id":"t5","name":"Skill","input":{}}]}}"#,
            r#"{"type":"assistant","message":{"id":"m3","model":"<synthetic>","content":[]}}"#,
            "not json with \"type\":\"assistant\"",
            r#"{"type":"user","message":{"model":"claude-haiku-5-5","content":"Skill"}}"#,
        ];
        let u = uses(&tmpfile("uses", &body)).unwrap();
        assert_eq!(
            u.skills.into_iter().collect::<Vec<_>>(),
            [("debug".into(), 1), ("shepherd".into(), 2)]
        );
        assert_eq!(
            u.models.into_iter().collect::<Vec<_>>(),
            [
                ("claude-opus-5-5".into(), 1),
                ("claude-sonnet-5-5".into(), 1)
            ],
            "a streamed message counts once, a synthetic one and a user line not at all"
        );
        assert!(uses(Path::new("/no/such/transcript.jsonl")).is_err());

        // An unchanged file is not scanned again; a longer one is.
        let p = tmpfile(
            "uses-kept",
            &[r#"{"type":"user","message":{"content":"msg 1"}}"#],
        );
        assert!(uses(&p).unwrap().models.is_empty());
        fs::write(&p, body.join("\n")).unwrap();
        assert_eq!(uses(&p).unwrap().skills["shepherd"], 2);
        fs::remove_file(&p).ok();
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
    fn context_window_knows_claude_models_only() {
        assert_eq!(context_window("claude-opus-5-5"), Some(200_000));
        assert_eq!(context_window("claude-haiku-4-5-20251001"), Some(200_000));
        assert_eq!(context_window(""), None);
        assert_eq!(context_window("lazer"), None);
        assert_eq!(context_window("<synthetic>"), None);
    }

    #[test]
    fn last_entry_is_the_newest_timestamp_not_the_mtime() {
        let p = tmpfile(
            "stamp",
            &[
                r#"{"type":"user","timestamp":"2026-10-27T22:31:45.505Z","message":{"content":"x"}}"#,
                r#"{"type":"api-request","timestamp":"2026-10-27T22:31:45.595Z"}"#,
                r#"{"type":"system","timestamp":"2026-10-27T22:31:45.403Z","content":"{\"timestamp\":\"2030-01-01T00:00:00Z\"}"}"#,
                r#"{"type":"last-prompt"}"#,
            ],
        );
        // 2026-10-27T22:31:45Z, cross-checked with `date -ud @1793140305`.
        assert_eq!(fleet_info(&p).last_entry, Some(1_793_140_305));
        fs::remove_file(&p).ok();
        assert_eq!(
            fleet_info(Path::new("/no/such/file.jsonl")).last_entry,
            None
        );
        assert_eq!(iso_epoch("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_epoch("2024-02-29T12:00:00.5Z"), Some(1_709_208_000));
        assert_eq!(iso_epoch("2026-10-27 22:31:45"), None);
    }

    #[test]
    fn edited_files_come_from_edit_tool_inputs_only() {
        let p = tmpfile(
            "edits",
            &[
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/r/read-only.md"}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Edit","input":{"file_path":"/r/a.rs","old_string":"","new_string":""}},{"type":"tool_use","name":"Write","input":{"file_path":"/r/b.md","content":""}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/r/a.rs","edits":[]}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/r/n.ipynb"}}]}}"#,
                r#"{"type":"user","message":{"content":[{"type":"tool_result","content":""name":"Edit" "tool_use" /r/fake.md"}]}}"#,
            ],
        );
        assert_eq!(
            fleet_info(&p).edited_files,
            ["/r/a.rs", "/r/b.md", "/r/n.ipynb"]
        );
        fs::remove_file(&p).ok();
    }
}
