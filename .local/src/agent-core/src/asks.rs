//! Pending asks (`agent-ask`): which Claude sessions are waiting on the human.
//!
//! An ask is a file `<root>/<project>/<id>.md`
//! carrying a `status: pending` line, and it belongs to the session named on its
//! `claude_session: <id>` line. Only the asking session owns an ask; the tmux
//! session name is not a fallback. A parked ask (`parked_until` still ahead) is not pending,
//! the test of `agent-ask:is_parked` (fleet-states.md Owners, "Whether an ask is pending").

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// `$AGENT_ASK_ROOT`, else `~/.agent/asks`, as fleet-sessions resolves it.
pub fn root() -> PathBuf {
    std::env::var_os("AGENT_ASK_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::session::home().join(".agent").join("asks"))
}

/// The `question:` line of ask `id` under `root()`; empty when there is no such ask.
pub fn question(id: &str) -> String {
    let Ok(projects) = fs::read_dir(root()) else {
        return String::new();
    };
    projects
        .flatten()
        .find_map(|p| fs::read_to_string(p.path().join(format!("{id}.md"))).ok())
        .and_then(|t| {
            t.lines()
                .find_map(|l| l.strip_prefix("question: ").map(str::to_string))
        })
        .unwrap_or_default()
}

/// A pending ask is parked while its `parked_until` (UTC, `agent-ask`'s format) is after `now`
/// (epoch seconds). `agent-ask park` writes only that exact `YYYY-MM-DDTHH:MM:SSZ` form; unlike
/// the shell's string compare, a hand-edited value in another shape reads as not parked.
fn parked(text: &str, now: u64) -> bool {
    text.lines()
        .find_map(|l| l.strip_prefix("parked_until: "))
        .and_then(crate::transcript::iso_epoch)
        .is_some_and(|until| until > now)
}

/// Every pending, unparked ask under `root` as (its id, the Claude sessions it names): the `id:` line,
/// else the file name.
fn pending(root: &Path) -> Vec<(String, Vec<String>)> {
    let now = crate::now_secs();
    let mut out = Vec::new();
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
            if !text.lines().any(|l| l == "status: pending") || parked(&text, now) {
                continue;
            }
            let id = text
                .lines()
                .find_map(|l| l.strip_prefix("id: "))
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()))
                .unwrap_or_default();
            let sessions = text
                .lines()
                .filter_map(|l| l.strip_prefix("claude_session: "))
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
            out.push((id, sessions));
        }
    }
    out
}

/// Claude session id -> the id of a pending ask it owns under `root`. A session with several
/// keeps the first one read.
pub fn pending_sessions(root: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for (id, sessions) in pending(root) {
        for sid in sessions {
            out.entry(sid).or_insert_with(|| id.clone());
        }
    }
    out
}

/// How many pending asks under `root` name none of the `live` Claude sessions: a session that
/// ended, or no session at all (a headless job's). Prefix y is their only home.
pub fn without_live_owner(root: &Path, live: &HashSet<&str>) -> usize {
    pending(root)
        .iter()
        .filter(|(_, sessions)| !sessions.iter().any(|s| live.contains(s.as_str())))
        .count()
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
        // A headless job's ask names no session: it marks none, but it is still pending.
        ask(&root, "other", "a7", "pending", "");
        // A parked ask (date ahead) is not pending; one whose date has passed is again.
        let parked = |id: &str, session: &str, until: &str| {
            ask(&root, "other", id, "pending", session);
            let p = root.join("other").join(format!("{id}.md"));
            let t = fs::read_to_string(&p).unwrap();
            fs::write(&p, format!("{t}parked_until: {until}\n")).unwrap();
        };
        parked("a8", "sid-parked", "2999-01-01T00:00:00Z");
        parked("a9", "sid-lapsed", "2000-01-01T00:00:00Z");

        let got = pending_sessions(&root);
        let none_live = without_live_owner(&root, &HashSet::new());
        let a1_live = without_live_owner(&root, &HashSet::from(["sid-pending"]));
        let _ = fs::remove_dir_all(&root);
        assert_eq!(
            got,
            HashMap::from([
                ("sid-pending".to_string(), "a1".to_string()),
                ("sid-lapsed".to_string(), "a9".to_string()),
            ])
        );
        // a1, a7 and a9 are the pending ones; a1 drops out once its session is live.
        assert_eq!((none_live, a1_live), (3, 2));
    }

    #[test]
    fn missing_root_is_empty() {
        assert!(pending_sessions(Path::new("/nonexistent/agent-panel-asks")).is_empty());
        assert_eq!(
            without_live_owner(Path::new("/nonexistent/agent-panel-asks"), &HashSet::new()),
            0
        );
    }
}
