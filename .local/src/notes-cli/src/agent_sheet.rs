//! `<project>/agent/README.md` - the agents' own task sheet, and the link that reaches it.
//!
//! A SECOND SHEET, NOT A SECOND TAG. `#ai` on the human's sheet was right while only a
//! rendering was at stake. It could not fix WRITES: every agent `ptask` rewrote the human's
//! `README.md` (239 writes in four weeks against 43 to the agents' own notes), so the file
//! the human keeps open was the file the agents edited all day. A separate sheet fixes that
//! without reintroducing drift, because handing work over is a MOVE, not a copy: a row is
//! still in exactly one file, and which file IS the lane. Nothing here copies.
//!
//! STATIC, for every project, agent-touched or not. The old `ai/<ver>.md` was created
//! lazily and the cost was lost evidence: `gsuite-comms` finished an `#ai` task with no
//! note to record the proof in, so the proof is gone. A surface that exists only once it
//! is needed is not there when it is needed.

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
/// queue row, so an interrupted wave can be resumed. Neither is a filtered view of the other.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Lane {
    Human,
    Agent,
}

impl Lane {
    /// The directory whose task sheet this lane reads and writes.
    ///
    /// One parser, two paths: `project_tasks::task_sheet` resolves any dir carrying a
    /// `## Wave`, and the agent scaffold carries one deliberately for this reason.
    pub(crate) fn dir(self, project: &Path) -> PathBuf {
        match self {
            Lane::Human => project.to_path_buf(),
            Lane::Agent => projects::agent_dir(project),
        }
    }
}

/// The body a fresh agent sheet starts with: title, the version it tracks, a link home, and
/// an empty current wave named for that version.
///
/// Deliberately the same skeleton `projects::sheet_body` writes for the human, because every
/// reader downstream (`waves::sections`, `open_wave_for_dir`, the board, `ptask`) is the
/// human sheet's reader. A different skeleton here would mean a second parser, and a second
/// parser is a second set of bugs.
fn body(project: &str, ver: &str, home: &str) -> String {
    let link = if home.is_empty() {
        String::new()
    } else {
        format!("Human sheet: [[{home}|{project}]]\n")
    };
    format!(
        "# {project} - agent board\nVersion: {ver}\n{link}\n## {}\n- [ ] \n",
        crate::waves::heading_current(ver)
    )
}

/// Create `<project>/agent/README.md` if it is absent. Returns true when one was written.
///
/// Never touches an existing sheet: this runs from `notes board` and `notes today`, so it
/// fires several times a day against every project. Anything it rewrote, it would rewrite
/// under the agents mid-wave.
pub fn ensure(dir: &Path, project: &str, ver: &str, home: &str) -> Result<bool> {
    let path = sheet_path(dir);
    let fresh = body(project, ver, home);
    if let Ok(existing) = fs::read_to_string(&path) {
        // An UNTOUCHED scaffold is re-seeded when the human's version moves on, so a
        // brand-new agent board never shows a version the project left behind. The moment
        // it holds real work that stops: promoting a wave with tasks in it is a roll, and a
        // roll is not something a `notes today` may do behind the agents' backs.
        if is_untouched(&existing) && existing != fresh {
            md::write_atomic(&path, &fresh)?;
        }
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    md::write_atomic(&path, &fresh)?;
    Ok(true)
}

/// Does this sheet still hold nothing but its scaffold? True when no line is a task with
/// any text in it - the empty `- [ ] ` placeholder every fresh wave carries does not count.
fn is_untouched(content: &str) -> bool {
    !content
        .lines()
        .any(|l| md::is_task(l) && !md::task_text(l).trim().is_empty())
}

/// The `Agents:` line a human sheet carries, pointing at that project's agent board and at
/// the cross-project one.
///
/// DERIVED from the sheet's own `Version:` line rather than stored, so it cannot go stale:
/// a roll rewrites the head, and a link naming last version's note would be wrong from the
/// moment the roll finished. This is also why it is emitted by code and not hand-added -
/// `roll` rebuilds the head from `sheet_body` and would drop anything typed there.
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
    ver: &str,
    human_home: &str,
    agent_home: &str,
) -> Result<()> {
    if ensure(dir, project, ver, human_home)? {
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

/// One project's agent sheet, created if absent, with the same version and home link
/// `ensure_all` would give it.
///
/// The on-demand path for `ptask --agent`, and it goes through `ensure` rather than
/// `project_tasks::ensure_task_sheet`: that one scaffolds a bare sheet with no `Version:`
/// and no link home, which is a sheet the board can read but nothing can re-seed.
pub fn ensure_for(p: &crate::config::Profile, dir: &Path, project: &str) -> Result<PathBuf> {
    let ver = projects::fmt_version(projects::open_version(dir).unwrap_or((0, 0, 1)));
    let home = crate::project_tasks::task_sheet(dir)
        .map(|s| vault_rel(&p.vault, &s))
        .unwrap_or_default();
    ensure(dir, project, &ver, &home)?;
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
            let Some(dir) = summary.parent() else { continue };
            // No task sheet means no version to track and nothing to link from. A prose
            // brief is not a project that has started; scaffolding into it would put an
            // agent board on something with no wave to put work in.
            if crate::project_tasks::task_sheet(dir).is_none() {
                continue;
            }
            let ver = projects::fmt_version(projects::open_version(dir).unwrap_or((0, 0, 1)));
            let human_home = crate::project_tasks::task_sheet(dir)
                .map(|s| vault_rel(&p.vault, &s))
                .unwrap_or_default();
            let agent_home = vault_rel(&p.vault, &sheet_path(dir));
            if ensure_pair(log, dir, &proj, &ver, &human_home, &agent_home).is_ok() {
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
        let b = body("notes-cockpit", "v0.0.2", "lab/projects/current/notes-cockpit/README");
        assert!(b.starts_with("# notes-cockpit - agent board\nVersion: v0.0.2\n"), "{b}");
        assert!(b.contains("## Wave: v0.0.2 (current)"), "{b}");
        assert!(b.contains("- [ ] "), "{b}");
        // The human's reader must find the wave, or nothing downstream sees this file.
        assert_eq!(crate::waves::sections(&b).len(), 1, "{b}");
    }

    #[test]
    fn a_sheet_outside_the_vault_gets_no_dangling_link() {
        // Same rule `board::link_for` follows: an unlinked heading is a cosmetic loss, a
        // dangling wikilink is a broken promise.
        let b = body("stray", "v1.0.0", "");
        assert!(!b.contains("Human sheet:"), "{b}");
        assert!(b.contains("## Wave: v1.0.0 (current)"), "{b}");
    }

    #[test]
    fn the_link_lands_directly_under_the_version_line() {
        let sheet = "# demo\nVersion: v0.0.2\n\n## Wave: v0.0.2 (current)\n- [ ] a\n";
        let out = with_link(sheet, &link_line("lab/p/demo/agent/README")).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "# demo");
        assert_eq!(lines[1], "Version: v0.0.2");
        assert!(lines[2].starts_with("Agents: [[lab/p/demo/agent/README|agent board]]"), "{out}");
        assert!(lines[2].contains("[[lab/projects/agent-board|all projects]]"), "{out}");
        // and the wave is untouched below it
        assert!(out.contains("## Wave: v0.0.2 (current)\n- [ ] a\n"), "{out}");
    }

    #[test]
    fn re_linking_replaces_rather_than_stacks() {
        // This runs on every `notes today`. An append would grow the head without bound.
        let sheet = "# demo\nVersion: v0.0.2\n\n## Wave: v0.0.2 (current)\n";
        let once = with_link(sheet, &link_line("lab/p/demo/agent/README")).unwrap();
        assert!(with_link(&once, &link_line("lab/p/demo/agent/README")).is_none(), "no rewrite");
        assert_eq!(once.matches("Agents: ").count(), 1, "{once}");
    }

    #[test]
    fn a_rolled_version_moves_the_link_with_it() {
        // The link is derived, so a roll's new `Version:` produces a new target and the old
        // line is replaced, never left pointing at last version's note.
        let rolled = "# demo\nVersion: v0.0.3\nAgents: [[lab/p/demo/agent/README|agent board]] - [[lab/projects/agent-board|all projects]]\n\n## Wave: v0.0.3 (current)\n";
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
    fn an_untouched_scaffold_follows_the_human_version_forward() {
        // Otherwise a project that rolled before any agent touched it shows a brand-new
        // board stamped with the version the project already left behind.
        let dir = scratch("resync");
        assert!(ensure(&dir, "demo", "v0.0.1", "lab/p/demo/README").unwrap());

        assert!(!ensure(&dir, "demo", "v0.0.2", "lab/p/demo/README").unwrap());
        let got = fs::read_to_string(sheet_path(&dir)).unwrap();
        assert!(got.contains("Version: v0.0.2"), "{got}");
        assert!(got.contains("## Wave: v0.0.2 (current)"), "{got}");
        assert!(!got.contains("v0.0.1"), "no trace of the old version:\n{got}");
        let _ = fs::remove_dir_all(&dir);
    }

    // THE NEGATIVE CONTROL for the re-seed. Promoting a wave that holds real work is a
    // ROLL, and a roll is not something `notes today` may do behind the agents' backs.
    #[test]
    fn a_sheet_holding_real_work_is_never_re_seeded() {
        let dir = scratch("keepwork");
        assert!(ensure(&dir, "demo", "v0.0.1", "lab/p/demo/README").unwrap());
        let path = sheet_path(&dir);
        let worked = "# demo - agent board\nVersion: v0.0.1\n\n## Wave: v0.0.1 (current)\n- [/] half-finished thing\n";
        fs::write(&path, worked).unwrap();

        assert!(!ensure(&dir, "demo", "v0.0.9", "lab/p/demo/README").unwrap());
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            worked,
            "work in flight is never rewritten by a version bump"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_empty_placeholder_row_does_not_count_as_work() {
        // Every fresh wave carries `- [ ] `. Counting it would freeze the scaffold at the
        // version it was created with, which is the bug this whole path exists to avoid.
        assert!(is_untouched("# d - agent board\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] \n"));
        assert!(!is_untouched("# d - agent board\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] real\n"));
        assert!(!is_untouched("# d\n\n## Wave: v1 (current)\n- [x] done work\n"));
    }

    /// A scratch project dir, unique per test and per thread.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "agent-sheet-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
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

        assert!(ensure(&dir, "demo", "v0.1.0", "lab/p/demo/README").unwrap());
        let path = sheet_path(&dir);
        // Whatever the agents put here must survive every later `notes board`.
        fs::write(&path, "# demo - agent board\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] mid-wave work\n").unwrap();
        assert!(!ensure(&dir, "demo", "v0.1.0", "lab/p/demo/README").unwrap());
        assert!(
            fs::read_to_string(&path).unwrap().contains("mid-wave work"),
            "an existing sheet is never rewritten"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
