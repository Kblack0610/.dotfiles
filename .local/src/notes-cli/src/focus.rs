//! `notes focus` — the daily cockpit's active-task list. Thin verbs over the daily
//! note's `## Focus` section (the "now / in progress" lane that `notes today` carries
//! forward, day-stamped). Writes stay in the CLI so the `<!-- since -->`/day-count stamp
//! convention and the rollup-sentinel boundary are always respected — the vault rule is
//! never hand-edit journal markdown, so "capture what I'm working on" is a verb here.
//!
//! - `list` (default) — print today's open Focus items (unchecked, real task lines).
//! - `add <text>`     — append `- [ ] <text>` under `## Focus`, freshly stamped.
//! - `done <query>`   — check off the first open item whose text matches `<query>`.
//!
//! The session-start hook (`session-preflight.sh`) surfaces the same open items at turn 1,
//! so the read side is shared: this is the write side.

use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use chrono::Local;
use std::fs;

/// The section every verb in this module operates on.
const FOCUS: &str = "Focus";

/// An open Focus task matching `query` (already lower-cased) by normalised text. The one
/// predicate `done` and `rm` share, so they can never disagree about what is selectable.
fn is_match(line: &str, query: &str) -> bool {
    md::is_open_task(line) && md::task_key(line).contains(query)
}

/// Open Focus tasks in `content` (prose, `---` rules, checked items and the empty `- [ ]`
/// placeholder excluded). [`md::section_lines`] resolves the authored region via
/// `md::section_span`, so mirrored job tasks past a [`md::ROLLUP_START`] are never listed.
fn open_focus(content: &str) -> Vec<String> {
    md::section_lines(content, FOCUS)
        .unwrap_or_default()
        .into_iter()
        .filter(|l| md::is_open_task(l))
        .collect()
}

/// Pure core of `done`: tick the first OPEN `## Focus` task matching `query`. Returns
/// `(new_content, closed_line)` — the closed line as it now reads, i.e. already flipped —
/// or `None` when nothing matches.
fn close_first(content: &str, query: &str) -> Option<(String, String)> {
    md::edit_first_in_section(
        content,
        FOCUS,
        |l| is_match(l, query),
        // Flip the checkbox structurally rather than replacing a literal `- [ ]`: an
        // in-progress `- [/]` task is open, and a literal replace would silently no-op.
        |l| Some(md::set_checkbox(l, 'x')),
    )
    .map(|(new_content, matched)| (new_content, md::set_checkbox(&matched, 'x')))
}

/// Pure core of `rm`: DELETE the first OPEN `## Focus` task matching `query` — the line
/// goes away entirely, unlike [`close_first`] which only ticks it. Returns
/// `(new_content, removed_line)`, or `None` when nothing matches.
fn remove_first(content: &str, query: &str) -> Option<(String, String)> {
    md::edit_first_in_section(content, FOCUS, |l| is_match(l, query), |_| None)
}

/// Open Focus tasks with their 1-based file line number and dedup key. The cross-profile
/// cockpit needs the position to JUMP to a task and the key to CLOSE it (`focus done`
/// matches on `md::task_key`). Shares [`md::section_span`]'s authored-region boundary with
/// every other verb here, so the read and write sides cannot disagree about what exists.
fn open_focus_positions(content: &str) -> Vec<(usize, String, String)> {
    md::section_numbered(content, FOCUS)
        .into_iter()
        .filter(|(_, l)| md::is_open_task(l))
        .map(|(n, l)| (n, md::task_key(l), l.trim_end().to_string()))
        .collect()
}

/// `notes focus --all` — aggregate every configured profile's open Focus items for the
/// cross-profile cockpit. One TSV row per open task:
/// `profile <TAB> file <TAB> line <TAB> key <TAB> text`. Read-only; the caller closes a
/// task with `notes --profile <profile> focus done "<key>"` and jumps with `file`+`line`.
/// A profile that fails to resolve, whose today note is absent, or whose note cannot be
/// READ (permissions, a dead sync symlink, a directory at that path) is skipped silently —
/// this runs from editor integration, so one broken profile must not abort the rest.
pub fn list_all(_log: &Logger) -> Result<i32> {
    for name in config::all_profile_names()? {
        let Ok(p) = config::resolve(Some(&name)) else {
            continue;
        };
        let note = daily::today_path(&p);
        let Ok(content) = fs::read_to_string(&note) else {
            continue; // absent or unreadable — one bad profile must not blank the cockpit
        };
        let file = note.display();
        for (line, key, text) in open_focus_positions(&content) {
            println!("{name}\t{file}\t{line}\t{key}\t{text}");
        }
    }
    Ok(0)
}

/// `notes focus` / `notes focus list` — today's open cockpit items, one per line.
pub fn list(p: &Profile, _log: &Logger) -> Result<i32> {
    let note = daily::today_path(p);
    let items = if note.exists() {
        open_focus(&fs::read_to_string(&note)?)
    } else {
        Vec::new()
    };
    if items.is_empty() {
        println!("focus clear — add one: notes focus add \"<a couple words>\"");
        return Ok(0);
    }
    for l in &items {
        println!("{l}");
    }
    Ok(0)
}

/// `notes focus add <text>` — append a new open task under today's `## Focus`, stamped
/// `(0d) <!-- since:today -->` like every other daily item. Bootstraps today's note first
/// when absent (idempotent `notes today`), so the section normally exists to insert under.
///
/// Refuses when the note has no `## Focus` heading rather than trusting
/// [`md::insert_under_heading`]'s fallback, which appends a fresh section at EOF — i.e.
/// BELOW the `---\nBacklogs:` footer. Tomorrow's `strip_backlog_footer` truncates from
/// that footer, so such a section (and every task in it) would be destroyed overnight with
/// no carry-forward. The bootstrap only guarantees the heading for notes this CLI created;
/// a synced, job, or hand-edited note can legitimately lack it.
pub fn add(p: &Profile, log: &Logger, text: &str) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text — a couple words)");
    }
    let note = daily::today_path(p);
    if !note.exists() {
        daily::run(p, log)?; // create today's note + `## Focus` (carry-forward, refs, etc.)
    }
    let content = fs::read_to_string(&note)?;
    if md::section_lines(&content, "Focus").is_none() {
        bail!(
            "no `## Focus` section in {} — refusing to append (it would land below the \
             backlog footer and be truncated by tomorrow's carry). Run `notes today` first.",
            note.display()
        );
    }
    let today = Local::now().date_naive();
    let line = md::stamp_line(&format!("- [ ] {text}"), today, today);
    let new_content = md::insert_under_heading(&content, "Focus", std::slice::from_ref(&line));
    md::write_atomic(&note, &new_content)?;
    log.info("focus", &format!("added to {}", note.display()));
    println!("{line}");
    Ok(0)
}

/// `notes focus done <query>` — check off the first OPEN task under today's `## Focus`
/// whose normalised text contains `<query>` (case-insensitive). Reports what was closed,
/// or lists the open items when nothing matches so the caller can retry.
///
/// Exits non-zero on no-match: the cockpit drives this through fzf's `execute-silent`,
/// which discards stdout, so a zero exit would make "matched nothing" indistinguishable
/// from "closed it". The advisory goes to stderr for the same reason.
pub fn done(p: &Profile, log: &Logger, query: &str) -> Result<i32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let note = daily::today_path(p);
    if !note.exists() {
        bail!("no daily note yet — run: notes today");
    }
    let content = fs::read_to_string(&note)?;
    match close_first(&content, &query) {
        Some((new_content, closed)) => {
            md::write_atomic(&note, &new_content)?;
            log.info("focus", &format!("done in {}", note.display()));
            println!("done {}", closed.trim());
            Ok(0)
        }
        None => {
            eprintln!("no open focus item matches '{query}'. Open now:");
            for l in open_focus(&content) {
                eprintln!("  {l}");
            }
            Ok(1)
        }
    }
}

/// `notes focus rm <query>` — DELETE the first open `## Focus` task whose text matches
/// `<query>` (case-insensitive), removing the line. Reports what was removed, or lists
/// the open items when nothing matches so the caller can retry. Exits non-zero on
/// no-match, for the same `execute-silent` reason as [`done`].
pub fn rm(p: &Profile, log: &Logger, query: &str) -> Result<i32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let note = daily::today_path(p);
    if !note.exists() {
        bail!("no daily note yet — run: notes today");
    }
    let content = fs::read_to_string(&note)?;
    match remove_first(&content, &query) {
        Some((new_content, removed)) => {
            md::write_atomic(&note, &new_content)?;
            log.info("focus", &format!("removed in {}", note.display()));
            println!("removed {}", removed.trim());
            Ok(0)
        }
        None => {
            eprintln!("no open focus item matches '{query}'. Open now:");
            for l in open_focus(&content) {
                eprintln!("  {l}");
            }
            Ok(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "\
# 2026-07-16

## Focus
- [ ] buy backup drive (2d) <!-- since:2026-07-14 -->
- [x] disassemble venty (1d) <!-- since:2026-07-15 -->
- for universal boot
- [ ]
    - [ ] admin local ui (2d) <!-- since:2026-07-13 -->

## Notes
after
";

    #[test]
    fn open_focus_filters_prose_checked_and_placeholder() {
        let items = open_focus(NOTE);
        assert_eq!(
            items,
            vec![
                "- [ ] buy backup drive (2d) <!-- since:2026-07-14 -->".to_string(),
                "    - [ ] admin local ui (2d) <!-- since:2026-07-13 -->".to_string(),
            ]
        );
        // Prose, the checked item, and the empty `- [ ]` placeholder are all excluded.
        assert!(!items.iter().any(|l| l.contains("universal boot")));
        assert!(!items.iter().any(|l| md::is_checked(l)));
        assert!(!items.iter().any(|l| md::is_empty_unchecked(l)));
    }

    #[test]
    fn open_focus_positions_reports_line_numbers_and_keys() {
        let items = open_focus_positions(NOTE);
        // `## Focus` sits at line 3; the two OPEN tasks are at lines 4 and 8.
        // The checked item, the prose line, and the empty placeholder are excluded.
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].0, 4);
        assert_eq!(items[0].1, "buy backup drive");
        assert!(items[0].2.contains("buy backup drive"));
        assert_eq!(items[1].0, 8);
        assert_eq!(items[1].1, "admin local ui");
        // Indentation is preserved in the emitted text (jump lands on the right line).
        assert!(items[1].2.starts_with("    - [ ]"));
    }

    #[test]
    fn open_focus_positions_stops_at_rollup_sentinel() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n\n### acmecorp\n- [ ] theirs\n\n## Notes\n",
            md::ROLLUP_START
        );
        let items = open_focus_positions(&note);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].1, "mine");
    }

    #[test]
    fn open_focus_stops_at_rollup_sentinel() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n\n### acmecorp\n- [ ] theirs\n\n## Notes\n",
            md::ROLLUP_START
        );
        assert_eq!(open_focus(&note), vec!["- [ ] mine".to_string()]);
    }

    #[test]
    fn close_first_ticks_matching_open_task() {
        let (out, closed) = close_first(NOTE, "backup").unwrap();
        assert_eq!(
            closed,
            "- [x] buy backup drive (2d) <!-- since:2026-07-14 -->"
        );
        assert!(out.contains("- [x] buy backup drive"));
        // Only the matched line flips; the other open task stays open.
        assert!(out.contains("    - [ ] admin local ui"));
        // Trailing newline shape is preserved.
        assert!(out.ends_with("after\n"));
    }

    #[test]
    fn close_first_matches_indented_task_by_substring() {
        let (out, closed) = close_first(NOTE, "admin").unwrap();
        assert_eq!(
            closed,
            "    - [x] admin local ui (2d) <!-- since:2026-07-13 -->"
        );
        assert!(out.contains("    - [x] admin local ui"));
        // Indentation is preserved when the checkbox flips.
        assert!(out.contains("\n    - [x]"));
    }

    /// The regression test for the bug this module shipped with: an in-progress `- [/]`
    /// task passes the open-task filter, so `close_first` matched it and reported success
    /// — but the mutation was `replacen("- [ ]", "- [x]")`, which finds nothing in a
    /// `- [/]` line. The task silently stayed open. This is the cockpit's ctrl-x path.
    #[test]
    fn close_first_closes_an_in_progress_task() {
        let note = "## Focus\n- [/] wire it up (2d) <!-- since:2026-07-14 -->\n\n## Notes\n";
        let (out, closed) = close_first(note, "wire").unwrap();
        assert_eq!(closed, "- [x] wire it up (2d) <!-- since:2026-07-14 -->");
        assert!(out.contains("- [x] wire it up"));
        assert!(!out.contains("- [/]"), "the in-progress mark must be gone");
    }

    #[test]
    fn close_first_closes_an_indented_in_progress_task() {
        let note = "## Focus\n    - [/] sub-step\n\n## Notes\n";
        let (out, closed) = close_first(note, "sub-step").unwrap();
        assert_eq!(closed, "    - [x] sub-step");
        assert!(out.contains("\n    - [x] sub-step"));
    }

    #[test]
    fn remove_first_deletes_an_in_progress_task() {
        let note = "## Focus\n- [/] wire it up\n- [ ] other\n\n## Notes\n";
        let (out, removed) = remove_first(note, "wire").unwrap();
        assert_eq!(removed, "- [/] wire it up");
        assert!(!out.contains("wire it up"));
        assert!(out.contains("- [ ] other"));
    }

    /// Read and write must agree about which tasks exist. The hand-rolled walks used to
    /// re-arm on a SECOND `## Focus` heading while `md::capture` stopped at the first
    /// section end, so `list` hid a task that `done`/`rm` would happily edit. Sharing
    /// `md::section_span` makes both sides see only the first section.
    #[test]
    fn read_and_write_agree_on_a_duplicated_focus_heading() {
        let note = "## Focus\n- [ ] first\n\n## Notes\n\n## Focus\n- [ ] second\n";
        // The reader only sees the first section...
        assert_eq!(open_focus(note), vec!["- [ ] first".to_string()]);
        assert_eq!(open_focus_positions(note).len(), 1);
        // ...so the writers must refuse to touch the second one.
        assert!(close_first(note, "second").is_none());
        assert!(remove_first(note, "second").is_none());
        // The first-section task is still editable.
        assert_eq!(close_first(note, "first").unwrap().1, "- [x] first");
    }

    #[test]
    fn close_first_none_when_no_match() {
        assert!(close_first(NOTE, "nonexistent").is_none());
        // A query that only matches the already-checked item does not re-close it.
        assert!(close_first(NOTE, "venty").is_none());
    }

    #[test]
    fn close_first_ignores_tasks_past_the_rollup_sentinel() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n- [ ] mirrored theirs\n\n## Notes\n",
            md::ROLLUP_START
        );
        // A query that only hits the mirrored (post-sentinel) task must not tick it.
        assert!(close_first(&note, "mirrored").is_none());
        // The authored task still closes.
        let (_out, closed) = close_first(&note, "mine").unwrap();
        assert_eq!(closed, "- [x] mine");
    }

    #[test]
    fn close_first_only_closes_one_even_with_two_matches() {
        let note = "## Focus\n- [ ] fix the bug\n- [ ] fix the other bug\n\n## Notes\n";
        let (out, closed) = close_first(note, "fix").unwrap();
        assert_eq!(closed, "- [x] fix the bug");
        // The second match remains open — done() closes one at a time.
        assert!(out.contains("- [ ] fix the other bug"));
        assert!(!out.contains("- [x] fix the other bug"));
    }

    #[test]
    fn remove_first_deletes_matching_open_task() {
        let (out, removed) = remove_first(NOTE, "backup").unwrap();
        assert_eq!(
            removed,
            "- [ ] buy backup drive (2d) <!-- since:2026-07-14 -->"
        );
        // The line is gone entirely (not just ticked).
        assert!(!out.contains("buy backup drive"));
        // The other open task and the checked one are untouched.
        assert!(out.contains("    - [ ] admin local ui"));
        assert!(out.contains("- [x] disassemble venty"));
        assert!(out.ends_with("after\n"));
    }

    #[test]
    fn remove_first_ignores_tasks_past_the_rollup_sentinel() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n- [ ] mirrored theirs\n\n## Notes\n",
            md::ROLLUP_START
        );
        // A mirrored (post-sentinel) task must never be removed.
        assert!(remove_first(&note, "mirrored").is_none());
        let (_out, removed) = remove_first(&note, "mine").unwrap();
        assert_eq!(removed, "- [ ] mine");
    }
}
