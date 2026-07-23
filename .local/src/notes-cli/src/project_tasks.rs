//! `notes ptask <name> …` — a project's task list, living on the project SHEET's current
//! `## Wave` section (the first `## Wave…` heading). The project analog of `notes focus`
//! (which is the daily note's `## Focus`): project tasks belong in the project `.md` — the
//! template-driven, version-scoped source of truth — so `notes projects --roll` freezes a
//! REAL task list into `versions/`, and the daily note keeps only the untagged main tasks.
//!
//! Mirrors `focus.rs` verb-for-verb but points the SAME generic `md` helpers at a resolved
//! wave heading instead of the hard-coded `## Focus`. The task SHEET is README.md/tasks.md
//! that carries a `## Wave` — decoupled from the `Version:` line, so a release-managed
//! project (version in `changelog/`) can hold a task sheet without owning its version there.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use crate::projects;
use anyhow::{bail, Result};
use std::fs;
use std::path::{Path, PathBuf};

/// The current wave's heading TEXT — the first `## Wave…` line's text (e.g.
/// `"Wave: new (current)"`). `md::section_span` matches a heading exactly, so callers
/// resolve the live text rather than assuming a fixed string.
fn current_wave(content: &str) -> Option<String> {
    content.lines().find_map(|l| {
        let rest = l.strip_prefix("## ")?;
        rest.trim_start()
            .starts_with("Wave")
            .then(|| rest.trim().to_string())
    })
}

/// The project's TASK sheet: `README.md` then `tasks.md`, whichever carries a `## Wave`.
fn task_sheet(dir: &Path) -> Option<PathBuf> {
    ["README.md", "tasks.md"].iter().find_map(|n| {
        let p = dir.join(n);
        fs::read_to_string(&p)
            .ok()
            .filter(|c| current_wave(c).is_some())
            .map(|_| p)
    })
}

/// Resolve (or create) a project's task sheet. Prefers an existing `## Wave` sheet; else
/// appends a `## Wave: new (current)` to an existing `README.md`; else scaffolds a fresh
/// `README.md` task sheet. `name` seeds the title of a fresh sheet.
fn ensure_task_sheet(dir: &Path, name: &str) -> Result<PathBuf> {
    if let Some(s) = task_sheet(dir) {
        return Ok(s);
    }
    let readme = dir.join("README.md");
    if let Ok(mut c) = fs::read_to_string(&readme) {
        if !c.ends_with('\n') {
            c.push('\n');
        }
        c.push_str("\n## Wave: new (current)\n- [ ] \n");
        md::write_atomic(&readme, &c)?;
    } else {
        fs::write(
            &readme,
            format!("# {name}\n\n## Wave: new (current)\n- [ ] \n"),
        )?;
    }
    Ok(readme)
}

/// The sheet + its resolved current-wave heading, for a named project. `None` when the
/// project has no task sheet yet (a read verb then lists nothing).
fn sheet_and_wave(p: &Profile, name: &str) -> Result<Option<(PathBuf, String, String)>> {
    let dir = projects::project_dir(p, name)?;
    let Some(sheet) = task_sheet(&dir) else {
        return Ok(None);
    };
    let content = fs::read_to_string(&sheet)?;
    match current_wave(&content) {
        Some(h) => Ok(Some((sheet, h, content))),
        None => Ok(None),
    }
}

/// An open wave task matching `query` (already lower-cased) — the shared predicate for
/// `done`/`start`/`rm`, matching `focus.rs::is_match`.
fn is_match(line: &str, query: &str) -> bool {
    md::is_open_task(line) && md::task_key(line).contains(query)
}

/// `notes ptask <name> list` — TSV `path<TAB>line<TAB>key<TAB>text` of the current wave's
/// OPEN tasks (the cockpit's per-project data source; parallels `focus::open_focus_positions`).
pub fn list(p: &Profile, name: &str) -> Result<i32> {
    let Some((sheet, heading, content)) = sheet_and_wave(p, name)? else {
        return Ok(0);
    };
    let file = sheet.display();
    for (n, l) in md::section_numbered(&content, &heading) {
        if md::is_open_task(l) {
            println!("{file}\t{n}\t{}\t{}", md::task_key(l), l.trim_end());
        }
    }
    Ok(0)
}

/// `notes ptask <name> add <text>` — append `- [ ] <text>` under the current wave, creating
/// the task sheet if the project has none. Unlike daily `focus add`, wave tasks are NOT
/// day-stamped (they live in the version's wave until done or rolled, not carried forward).
pub fn add(p: &Profile, log: &Logger, name: &str, text: &str) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text)");
    }
    let dir = projects::project_dir(p, name)?;
    let sheet = ensure_task_sheet(&dir, name)?;
    let content = fs::read_to_string(&sheet)?;
    let Some(heading) = current_wave(&content) else {
        bail!("no `## Wave` section in {}", sheet.display());
    };
    let line = format!("- [ ] {text}");
    let new = md::insert_under_heading(&content, &heading, std::slice::from_ref(&line));
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("added to {} ({name})", sheet.display()));
    println!("{line}");
    Ok(0)
}

/// `notes ptask <name> done <query>` — check off the first open wave task matching `<query>`.
pub fn done(p: &Profile, log: &Logger, name: &str, query: &str) -> Result<i32> {
    edit(p, log, name, query, "done", |l| Some(md::set_checkbox(l, 'x')))
}

/// `notes ptask <name> rm <query>` — delete the first open wave task matching `<query>`.
pub fn rm(p: &Profile, log: &Logger, name: &str, query: &str) -> Result<i32> {
    edit(p, log, name, query, "removed", |_| None)
}

/// `notes ptask <name> start <query>` — toggle the first matching wave task between todo
/// (`[ ]`) and in-progress (`[/]`).
pub fn start(p: &Profile, log: &Logger, name: &str, query: &str) -> Result<i32> {
    edit(p, log, name, query, "toggled", |l| {
        let mark = if l.trim_start().starts_with("- [/]") {
            ' '
        } else {
            '/'
        };
        Some(md::set_checkbox(l, mark))
    })
}

/// Shared body for `done`/`rm`/`start`: apply `f` to the first open wave task matching
/// `query`. Non-zero exit on no-match (the cockpit drives these through `execute-silent`,
/// which discards stdout, so a zero exit would hide "matched nothing").
fn edit<F>(p: &Profile, log: &Logger, name: &str, query: &str, verb: &str, f: F) -> Result<i32>
where
    F: Fn(&str) -> Option<String>,
{
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let Some((sheet, heading, content)) = sheet_and_wave(p, name)? else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    match md::edit_first_in_section(&content, &heading, |l| is_match(l, &query), f) {
        Some((new, matched)) => {
            md::write_atomic(&sheet, &new)?;
            log.info("ptask", &format!("{verb} in {} ({name})", sheet.display()));
            println!("{verb} {}", matched.trim());
            Ok(0)
        }
        None => {
            eprintln!("no open task matches '{query}' in {name}");
            Ok(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "\
# demo
Version: v0.1.0

## Wave: new (current)
- [ ] first task
- [x] done task
- [/] doing this
- [ ] second task

## Backlog
- [ ] later
";

    #[test]
    fn current_wave_finds_the_first_wave_heading() {
        assert_eq!(current_wave(SHEET).as_deref(), Some("Wave: new (current)"));
        assert_eq!(current_wave("# x\n\n## Notes\n- [ ] a\n"), None);
    }

    #[test]
    fn list_positions_cover_only_open_wave_tasks() {
        let h = current_wave(SHEET).unwrap();
        let open: Vec<_> = md::section_numbered(SHEET, &h)
            .into_iter()
            .filter(|(_, l)| md::is_open_task(l))
            .map(|(_, l)| md::task_key(l))
            .collect();
        // the two todos + the in-progress task; NOT the checked one, NOT the backlog item
        assert_eq!(open, vec!["first task", "doing this", "second task"]);
    }

    #[test]
    fn edit_first_ticks_only_the_matching_wave_task() {
        let h = current_wave(SHEET).unwrap();
        let (out, matched) =
            md::edit_first_in_section(SHEET, &h, |l| is_match(l, "second"), |l| {
                Some(md::set_checkbox(l, 'x'))
            })
            .unwrap();
        assert!(matched.contains("second task"));
        assert!(out.contains("- [x] second task"));
        // the backlog task in the next section is untouched
        assert!(out.contains("## Backlog\n- [ ] later"));
    }

    #[test]
    fn start_toggles_todo_and_in_progress() {
        let h = current_wave(SHEET).unwrap();
        let toggle = |l: &str| -> Option<String> {
            let mark = if l.trim_start().starts_with("- [/]") {
                ' '
            } else {
                '/'
            };
            Some(md::set_checkbox(l, mark))
        };
        let (out, _) =
            md::edit_first_in_section(SHEET, &h, |l| is_match(l, "first"), toggle).unwrap();
        assert!(out.contains("- [/] first task"));
    }
}
