//! Pending asks (`agent-ask`): which Claude sessions are waiting on the human.
//!
//! The rule is `asks_for` in `.local/bin/fleet-sessions`, kept identical so the
//! panel and the fleet board agree: an ask is a file `<root>/<project>/<id>.md`
//! carrying a `status: pending` line, and it belongs to the session named on its
//! `claude_session: <id>` line. Only the asking session owns an ask; the tmux
//! session name is not a fallback.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// `$AGENT_ASK_DIR`, else `~/.agent/asks`, as fleet-sessions resolves it.
pub fn root() -> PathBuf {
    std::env::var_os("AGENT_ASK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::session::home().join(".agent").join("asks"))
}

/// Claude session id -> the id of a pending ask it owns under `root` (its `id:` line, else
/// the file name). A session with several keeps the first one read.
pub fn pending_sessions(root: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Ok(projects) = fs::read_dir(root) else {
        return out;
    };
    for project in projects.flatten() {
        let Ok(files) = fs::read_dir(project.path()) else {
            continue;
        };
        for file in files.flatten() {
            let path = file.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            if !text.lines().any(|l| l == "status: pending") {
                continue;
            }
            let id = text
                .lines()
                .find_map(|l| l.strip_prefix("id: "))
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()))
                .unwrap_or_default();
            for sid in text
                .lines()
                .filter_map(|l| l.strip_prefix("claude_session: "))
                .filter(|s| !s.is_empty())
            {
                out.entry(sid.to_string()).or_insert_with(|| id.clone());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(root: &Path, project: &str, id: &str, status: &str, session: &str) {
        let dir = root.join(project);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(format!("{id}.md")),
            format!("id: {id}\nproject: {project}\nstatus: {status}\nclaude_session: {session}\nquestion: ok?\n"),
        )
        .unwrap();
    }

    #[test]
    fn only_pending_asks_mark_their_own_session() {
        let root = std::env::temp_dir().join(format!("agent-panel-asks-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        ask(&root, "dotfiles", "a1", "pending", "sid-pending");
        // Negative controls: the same rule must leave these sessions unmarked.
        ask(&root, "dotfiles", "a2", "answered", "sid-answered");
        ask(&root, "other", "a3", "cancelled", "sid-cancelled");
        ask(&root, "other", "a4", "stale", "sid-stale");
        // A `pending` word anywhere but the status line is not pending.
        fs::write(
            root.join("other").join("a5.md"),
            "status: answered\nclaude_session: sid-mention\nanswer: pending review\n",
        )
        .unwrap();
        // Not an ask file.
        fs::write(
            root.join("other").join("a6.txt"),
            "status: pending\nclaude_session: sid-txt\n",
        )
        .unwrap();

        let got = pending_sessions(&root);
        let _ = fs::remove_dir_all(&root);
        assert_eq!(
            got,
            HashMap::from([("sid-pending".to_string(), "a1".to_string())])
        );
    }

    #[test]
    fn missing_root_is_empty() {
        assert!(pending_sessions(Path::new("/nonexistent/agent-panel-asks")).is_empty());
    }
}
