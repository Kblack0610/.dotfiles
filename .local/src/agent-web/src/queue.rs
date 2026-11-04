//! The Queue tab: agent-queue's items, and adding, cancelling and re-ranking them.
//!
//! agent-queue is the only writer of `~/.agent/queue` (design: `~/.config/agentctl/QUEUE.md`).
//! The list, cancel and bump go through `hub_core::queue`, which the hub TUI reads too; add
//! shells out here, since its task goes on stdin. Every call is plain arguments, never a shell,
//! and agent-queue's stderr comes back as the error the page shows.

use axum::http::StatusCode;
use axum::Json;
use hub_core::queue::{self as hub_queue, Item, PRIORITIES};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, run_cmd, ApiResult};

const MODES: &[&str] = &["oneshot", "plan"];

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

/// Every active item plus today's finished ones, in queue order, read through hub-core.
pub async fn list() -> ApiResult<Json<Vec<Item>>> {
    tokio::task::spawn_blocking(|| hub_queue::list(&System, "all"))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}

/// The window's line and what sits now, worded by hub-core as the hub TUI words them.
pub async fn stats() -> ApiResult<Json<serde_json::Value>> {
    let s = tokio::task::spawn_blocking(|| hub_queue::stats(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(
        serde_json::json!({ "week": s.week(), "sitting": s.sitting_line() }),
    ))
}

/// Cancel or bump through hub-core, which checks the slug and priority and runs agent-queue.
async fn act(f: impl FnOnce() -> Result<String, String> + Send + 'static) -> ApiResult<StatusCode> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
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
    let mode = if b.mode.is_empty() {
        "oneshot"
    } else {
        &b.mode
    };
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
    let out = run_cmd("agent-queue", &argv, Some(b.task.trim())).await?;
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[derive(Deserialize)]
pub struct SlugBody {
    slug: String,
    #[serde(default)]
    priority: String,
}

pub async fn cancel(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    act(move || hub_queue::cancel(&System, &b.slug)).await
}

pub async fn bump(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    act(move || hub_queue::bump(&System, &b.slug, &b.priority)).await
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
