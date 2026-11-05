//! `<project>/agent/README.md` - the agents' own task sheet, and the link that reaches it.
//!
//! A WORKING BOARD, NOT A SECOND QUEUE. The project's own `README.md` is the queue - every
//! open item, whoever does it, and where done-ness is recorded. This is what the agents
//! write underneath it: the subtasks and in-flight state below a queue row, so work
//! interrupted halfway can be picked up by a session that was not there for the first half.
//!
//! Nothing is handed over and nothing is filtered. A row is not routed here; it is either
//! work the human wants (the queue) or an agent's own breakdown of it (this). That is why
//! there is no tag: the file a row lives in IS what it is, so there is nothing to classify
//! and nothing that can disagree.
//!
//! It also settles WRITES, which a marker on one sheet could not: every agent `ptask` used
//! to rewrite the human's `README.md`, so the file the human keeps open was the file the
//! agents edited all day.
//!
//! STATIC, for every project, agent-touched or not. Created lazily, the cost was lost
//! evidence: work finished with no note to record the proof in, so the proof is gone.

use crate::logging::Logger;
use crate::md;
use crate::projects;
use anyhow::Result;
use std::fs;
use std::path::{Path, PathBuf};

/// The agents' sheet for a project: `<project>/agent/README.md`.
///
/// `README.md` and not `board.md` so the agents' half is the same shape as the human's half
/// one level down - a sheet beside its `versions/`. One pattern, learned once.
pub fn sheet_path(dir: &Path) -> PathBuf {
    projects::agent_dir(dir).join("README.md")
}

/// Which sheet a reader or writer is acting on: a directory, never a predicate. A row
/// belongs to whichever file it is written in, so there is nothing to classify.
///
/// The two are not symmetric. `Human` is the QUEUE - every open item, whoever does it, and
/// where done-ness is recorded. `Agent` is the WORKING board - subtasks and state under a
/// queue row, so interrupted work can be resumed. Neither is a filtered view of the other.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Lane {
    Human,
    Agent,
}

impl Lane {
    /// The directory whose task sheet this lane reads and writes.
    ///
    /// One parser, two paths: `project_tasks::task_sheet` resolves any dir carrying a
    /// `## Tasks`, and the agent scaffold carries one deliberately for this reason.
    pub(crate) fn dir(self, project: &Path) -> PathBuf {
        match self {
            Lane::Human => project.to_path_buf(),
            Lane::Agent => projects::agent_dir(project),
        }
    }
}

/// The body a fresh agent sheet starts with: title, a link home, and the empty sections. No
/// `Version:` line: the board follows its sheet, whose `Version:` an untagged row belongs to.
///
/// Deliberately the same skeleton `projects::sheet_body` writes for the human, because every
/// reader downstream (`sheet::open_rows`, `current_rows_for_dir`, the board, `ptask`) is the
/// human sheet's reader. A different skeleton here would mean a second parser, and a second
/// parser is a second set of bugs.
fn body(project: &str, home: &str) -> String {
    let link = if home.is_empty() {
        String::new()
    } else {
        format!("Human sheet: [[{home}|{project}]]\n")
    };
    format!(
        "# {project} - agent board\n{link}\n{}",
        crate::sheet::skeleton()
    )
}

/// Create `<project>/agent/README.md` if it is absent. Returns true when one was written.
///
/// Never touches an existing sheet: this runs from `notes board` and `notes today`, so it
/// fires several times a day against every project. Anything it rewrote, it would rewrite
/// under the agents mid-task.
pub fn ensure(dir: &Path, project: &str, home: &str) -> Result<bool> {
    let path = sheet_path(dir);
    if path.exists() {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    md::write_atomic(&path, &body(project, home))?;
    Ok(true)
}

/// The `Agents:` line a human sheet carries, pointing at that project's agent board and at
/// the cross-project one.
///
/// Emitted by code and not hand-added: `notes board` writes it where it is missing.
pub fn link_line(agent_home: &str) -> String {
    if agent_home.is_empty() {
        return String::new();
    }
    format!("Agents: [[{agent_home}|agent board]] - [[lab/projects/agent-board|all projects]]")
}

/// Put `line` directly under the sheet's `Version:` line, replacing any existing one.
///
/// Idempotent by construction: it removes the old `Agents:` line before inserting, so
/// running it on every board write cannot stack duplicates the way an append would. Returns
/// the new content, or `None` when nothing changed (the overwhelmingly common case, and the
/// one that must not cause a write).
pub fn with_link(content: &str, line: &str) -> Option<String> {
    let mut lines: Vec<String> = content
        .lines()
        .filter(|l| !l.trim_start().starts_with("Agents: "))
        .map(str::to_string)
        .collect();
    let at = lines
        .iter()
        .position(|l| l.trim_start().starts_with("Version:"))?;
    lines.insert(at + 1, line.to_string());
    let out = format!("{}\n", lines.join("\n"));
    (out != content).then_some(out)
}

/// Ensure both halves of the link for one project: the agent sheet exists, and the human's
/// sheet points at it.
///
/// Best-effort per project. A project whose sheet cannot be read is skipped rather than
/// fatal - this runs from `notes today`, and one unreadable sheet must not stop the note.
pub fn ensure_pair(
    log: &Logger,
    dir: &Path,
    project: &str,
    human_home: &str,
    agent_home: &str,
) -> Result<()> {
    if ensure(dir, project, human_home)? {
        log.info("agent", &format!("created {}", sheet_path(dir).display()));
    }
    let Some(sheet) = crate::project_tasks::task_sheet(dir) else {
        return Ok(());
    };
    let Ok(content) = fs::read_to_string(&sheet) else {
        return Ok(());
    };
    if let Some(out) = with_link(&content, &link_line(agent_home)) {
        md::write_atomic(&sheet, &out)?;
        log.info("agent", &format!("linked {}", sheet.display()));
    }
    Ok(())
}

/// A vault-relative wikilink target for `file`, or `""` when it is not under the vault.
///
/// The same fail-closed rule `board::link_for` follows, for the same reason: an unlinked
/// heading is a cosmetic loss, a dangling wikilink is a broken promise.
fn vault_rel(vault: &Path, file: &Path) -> String {
    let t = crate::config::wikilink(vault, file);
    if t.is_empty() || t.starts_with("..") || t.starts_with('/') {
        return String::new();
    }
    t
}

/// One project's agent sheet, created if absent, with the home link `ensure_all` would give
/// it.
///
/// The on-demand path for `ptask --agent`, and it goes through `ensure` rather than
/// `project_tasks::ensure_task_sheet`: that one scaffolds a bare sheet with no link home.
pub fn ensure_for(p: &crate::config::Profile, dir: &Path, project: &str) -> Result<PathBuf> {
    let home = crate::project_tasks::task_sheet(dir)
        .map(|s| vault_rel(&p.vault, &s))
        .unwrap_or_default();
    ensure(dir, project, &home)?;
    Ok(sheet_path(dir))
}

/// Give every project in every profile its agent sheet, and its human sheet the link.
///
/// Runs from `notes board` (so also from every `notes today`) rather than a one-off
/// migration, because "static" has to mean a project created tomorrow has one too. Both
/// halves are no-ops once satisfied, so the steady-state cost is a stat per project.
///
/// A profile that fails to resolve is skipped rather than fatal - the rule `write` already
/// follows, because one broken org must not stop the daily note being written.
pub fn ensure_all(log: &Logger) -> Result<usize> {
    let mut n = 0usize;
    for name in crate::config::all_profile_names()? {
        let Ok(p) = crate::config::resolve(Some(&name)) else {
            continue;
        };
        for (proj, summary) in crate::daily::discover_project_dirs(&p) {
            let Some(dir) = summary.parent() else {
                continue;
            };
            // No task sheet means nothing to link from. A prose
            // brief is not a project that has started; scaffolding into it would put an
            // agent board on something with no task section to put work in.
            let Some(human) = crate::project_tasks::task_sheet(dir) else {
                continue;
            };
            let human_home = vault_rel(&p.vault, &human);
            let agent_home = vault_rel(&p.vault, &sheet_path(dir));
            if ensure_pair(log, dir, &proj, &human_home, &agent_home).is_ok() {
                n += 1;
            }
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lane_resolves_to_a_directory_one_level_apart() {
        let p = Path::new("/v/projects/current/demo");
        assert_eq!(Lane::Human.dir(p), p);
        assert_eq!(Lane::Agent.dir(p), p.join("agent"));
        // The agent sheet sits where `sheet_path` puts it, so the board and `ptask --agent`
        // cannot disagree about which file the lane is.
        assert_eq!(Lane::Agent.dir(p).join("README.md"), sheet_path(p));
    }

    #[test]
    fn a_fresh_sheet_is_the_same_skeleton_the_human_gets() {
        let b = body("notes-cockpit", "lab/projects/current/notes-cockpit/README");
        assert!(
            b.starts_with("# notes-cockpit - agent board\nHuman sheet: "),
            "{b}"
        );
        assert!(
            !b.contains("Version:"),
            "the board follows its sheet's version:\n{b}"
        );
        assert!(b.ends_with(&crate::sheet::skeleton()), "{b}");
        // The human's reader must find the section, or nothing downstream sees this file.
        assert!(crate::sheet::has_tasks(&b), "{b}");
    }

    #[test]
    fn a_sheet_outside_the_vault_gets_no_dangling_link() {
        // Same rule `board::link_for` follows: an unlinked heading is a cosmetic loss, a
        // dangling wikilink is a broken promise.
        let b = body("stray", "");
        assert!(!b.contains("Human sheet:"), "{b}");
        assert!(crate::sheet::has_tasks(&b), "{b}");
    }

    #[test]
    fn the_link_lands_directly_under_the_version_line() {
        let sheet = "# demo\nVersion: v0.0.2\n\n## Tasks\n- [ ] a\n";
        let out = with_link(sheet, &link_line("lab/p/demo/agent/README")).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "# demo");
        assert_eq!(lines[1], "Version: v0.0.2");
        assert!(
            lines[2].starts_with("Agents: [[lab/p/demo/agent/README|agent board]]"),
            "{out}"
        );
        assert!(
            lines[2].contains("[[lab/projects/agent-board|all projects]]"),
            "{out}"
        );
        // and the section is untouched below it
        assert!(out.contains("## Tasks\n- [ ] a\n"), "{out}");
    }

    #[test]
    fn re_linking_replaces_rather_than_stacks() {
        // This runs on every `notes today`. An append would grow the head without bound.
        let sheet = "# demo\nVersion: v0.0.2\n\n## Tasks\n";
        let once = with_link(sheet, &link_line("lab/p/demo/agent/README")).unwrap();
        assert!(
            with_link(&once, &link_line("lab/p/demo/agent/README")).is_none(),
            "no rewrite"
        );
        assert_eq!(once.matches("Agents: ").count(), 1, "{once}");
    }

    #[test]
    fn a_moved_board_moves_the_link_with_it() {
        // The old line is replaced, never left pointing at a board that is gone.
        let rolled = "# demo\nVersion: v0.0.3\nAgents: [[lab/p/demo/agent/README|agent board]] - [[lab/projects/agent-board|all projects]]\n\n## Tasks\n";
        let out = with_link(rolled, &link_line("lab/p/demo/agent/README"));
        assert!(out.is_none(), "same target, so no write: {out:?}");

        let moved = with_link(rolled, &link_line("lab/other/demo/agent/README")).unwrap();
        assert_eq!(moved.matches("Agents: ").count(), 1, "{moved}");
        assert!(moved.contains("lab/other/demo/agent/README"), "{moved}");
        assert!(!moved.contains("lab/p/demo/agent/README"), "{moved}");
    }

    // THE NEGATIVE CONTROL. A prose brief with no `Version:` line is NOT a task sheet
    // (`sheet_path` accepts a README only when it declares one), and stamping a link onto
    // one would write into a file this feature has no business touching.
    #[test]
    fn a_sheet_with_no_version_line_is_never_stamped() {
        let prose = "# gsuite-comms\n\nMake GSuite manageable across 6+ accounts.\n";
        assert!(with_link(prose, &link_line("lab/p/x/agent/README")).is_none());
    }

    #[test]
    fn ensure_creates_once_and_then_leaves_it_alone() {
        let dir = std::env::temp_dir().join(format!(
            "agent-sheet-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        assert!(ensure(&dir, "demo", "lab/p/demo/README").unwrap());
        let path = sheet_path(&dir);
        // Whatever the agents put here must survive every later `notes board`.
        fs::write(
            &path,
            "# demo - agent board\n\n## Tasks\n- [ ] work in flight\n",
        )
        .unwrap();
        assert!(!ensure(&dir, "demo", "lab/p/demo/README").unwrap());
        assert!(
            fs::read_to_string(&path)
                .unwrap()
                .contains("work in flight"),
            "an existing sheet is never rewritten"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
