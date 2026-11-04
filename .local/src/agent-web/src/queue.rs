//! The Queue tab: agent-queue's items, and adding, cancelling and re-ranking them.
//!
//! agent-queue is the only writer of `~/.agent/queue` (design: `~/.config/agentctl/QUEUE.md`),
//! so every route here shells out to it with plain arguments, never a shell, and hands its
//! stderr back as the error the page shows.

use std::process::Stdio;

use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use tokio::io::AsyncWriteExt;

use crate::{bad, ApiResult};

const MODES: &[&str] = &["oneshot", "plan"];
const PRIORITIES: &[&str] = &["urgent", "high", "normal", "low"];

/// A slug or a project name: what agent-queue itself writes, so nothing else reaches its argv.
fn is_word(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

/// Tags are free words plus `at:HH:MM`; agent-queue checks the time, this only keeps them words.
fn is_tags(s: &str) -> bool {
    s.split([' ', ',']).filter(|t| !t.is_empty()).all(|t| {
        !t.starts_with('-')
            && t.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
    })
}

/// `agent-queue list --json` prints one object per line; a line that does not parse is skipped.
fn parse_items(jsonl: &str) -> Vec<serde_json::Value> {
    jsonl
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(serde_json::Value::is_object)
        .collect()
}

/// Run agent-queue; its stdout on success, its stderr as a 400 otherwise.
async fn run(args: &[&str], stdin: Option<&str>) -> ApiResult<String> {
    let mut cmd = tokio::process::Command::new("agent-queue");
    cmd.args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("agent-queue: {e}")))?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(text.as_bytes())
            .await
            .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("agent-queue: {e}")))?;
    }
    let out = child
        .wait_with_output()
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("agent-queue: {e}")))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(bad(
            StatusCode::BAD_REQUEST,
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ))
    }
}

/// Every active item plus today's finished ones, in queue order.
pub async fn list() -> ApiResult<Json<Vec<serde_json::Value>>> {
    let out = run(&["list", "--json", "--state", "all"], None).await?;
    Ok(Json(parse_items(&out)))
}

#[derive(Deserialize)]
pub struct AddBody {
    project: String,
    #[serde(default)]
    mode: String,
    #[serde(default)]
    priority: String,
    #[serde(default)]
    tags: String,
    task: String,
}

/// The argv for `agent-queue add`, or why the body is refused. The task goes on stdin.
fn add_args(b: &AddBody) -> Result<Vec<String>, &'static str> {
    let mode = if b.mode.is_empty() { "oneshot" } else { &b.mode };
    let priority = if b.priority.is_empty() {
        "normal"
    } else {
        &b.priority
    };
    if !is_word(&b.project) {
        return Err("pick a project");
    }
    if !MODES.contains(&mode) {
        return Err("mode is oneshot or plan");
    }
    if !PRIORITIES.contains(&priority) {
        return Err("priority is urgent, high, normal or low");
    }
    if !is_tags(&b.tags) {
        return Err("tags are words, or at:HH:MM");
    }
    if b.task.trim().is_empty() {
        return Err("type the task");
    }
    let mut args: Vec<String> = ["add", "--from", "human", "--project", &b.project]
        .into_iter()
        .chain(["--mode", mode, "--priority", priority])
        .map(String::from)
        .collect();
    if !b.tags.trim().is_empty() {
        args.extend(["--tags".into(), b.tags.trim().into()]);
    }
    Ok(args)
}

/// Queue a task; a plan item starts its session at once (agent-queue does that, not this).
pub async fn add(Json(b): Json<AddBody>) -> ApiResult<Json<serde_json::Value>> {
    let args = add_args(&b).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    let argv: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = run(&argv, Some(b.task.trim())).await?;
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[derive(Deserialize)]
pub struct SlugBody {
    slug: String,
    #[serde(default)]
    priority: String,
}

pub async fn cancel(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    if !is_word(&b.slug) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad slug"));
    }
    run(&["cancel", &b.slug], None).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn bump(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    if !is_word(&b.slug) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad slug"));
    }
    if !PRIORITIES.contains(&b.priority.as_str()) {
        return Err(bad(
            StatusCode::BAD_REQUEST,
            "priority is urgent, high, normal or low",
        ));
    }
    run(&["bump", &b.slug, &b.priority], None).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The projects a task may be queued for: the names in project-map.json, which is also what
/// agent-queue checks `--project` against.
pub async fn projects() -> Json<Vec<String>> {
    let path = std::env::var("AGENT_QUEUE_PROJECT_MAP").map_or_else(
        |_| agent_panel::session::home().join(".config/shared-hooks/project-map.json"),
        std::path::PathBuf::from,
    );
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    Json(project_names(&text))
}

fn project_names(map: &str) -> Vec<String> {
    let v: serde_json::Value = serde_json::from_str(map).unwrap_or_default();
    let mut names: Vec<String> = v
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(|p| p.as_str().map(String::from))
        .filter(|p| is_word(p))
        .collect();
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(project: &str, mode: &str, priority: &str, tags: &str, task: &str) -> AddBody {
        AddBody {
            project: project.into(),
            mode: mode.into(),
            priority: priority.into(),
            tags: tags.into(),
            task: task.into(),
        }
    }

    #[test]
    fn list_keeps_each_object_line_and_skips_the_rest() {
        let got = parse_items("{\"slug\":\"a\"}\n\nnot json\n[1]\n{\"slug\":\"b\"}\n");
        let slugs: Vec<&str> = got.iter().filter_map(|v| v["slug"].as_str()).collect();
        assert_eq!(slugs, ["a", "b"]);
    }

    #[test]
    fn add_defaults_to_a_normal_oneshot_from_the_human() {
        let args = add_args(&body("dotfiles", "", "", "", "do it")).unwrap();
        assert_eq!(
            args,
            [
                "add",
                "--from",
                "human",
                "--project",
                "dotfiles",
                "--mode",
                "oneshot",
                "--priority",
                "normal"
            ]
        );
        let args = add_args(&body("dotfiles", "plan", "high", "night at:02:30", "x")).unwrap();
        assert_eq!(args[args.len() - 2..], ["--tags", "night at:02:30"]);
    }

    #[test]
    fn add_refuses_what_would_reach_argv_as_an_option() {
        assert!(add_args(&body("--slug", "", "", "", "x")).is_err());
        assert!(add_args(&body("", "", "", "", "x")).is_err());
        assert!(add_args(&body("dotfiles", "wave", "", "", "x")).is_err());
        assert!(add_args(&body("dotfiles", "", "now", "", "x")).is_err());
        assert!(add_args(&body("dotfiles", "", "", "--after x", "x")).is_err());
        assert!(add_args(&body("dotfiles", "", "", "a;b", "x")).is_err());
        assert!(add_args(&body("dotfiles", "", "", "", "  \n")).is_err());
    }

    #[test]
    fn a_slug_is_one_word() {
        assert!(is_word("20261103-fix-the-menu"));
        assert!(!is_word("-rf"));
        assert!(!is_word("a b"));
        assert!(!is_word("../x"));
        assert!(!is_word(""));
    }

    #[test]
    fn projects_are_the_unique_map_values() {
        let map = r#"{"paths":{"/a":"dotfiles","/b":"notes-cockpit","/c":"dotfiles","/d":"-x"},"trackers":{}}"#;
        assert_eq!(project_names(map), ["dotfiles", "notes-cockpit"]);
        assert!(project_names("not json").is_empty());
    }
}
