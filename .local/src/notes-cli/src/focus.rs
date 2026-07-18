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

/// Open Focus tasks in `content`: unchecked, non-empty, real task lines only. Mirrors the
/// filter `daily::job_focus_tasks` uses (prose / `---` rules / empty placeholder excluded).
/// `md::section_lines` already stops at [`md::ROLLUP_START`], so mirrored job tasks from a
/// rollup block are never listed here.
fn open_focus(content: &str) -> Vec<String> {
    md::section_lines(content, "Focus")
        .unwrap_or_default()
        .into_iter()
        .filter(|l| md::is_task(l) && !md::is_checked(l) && !md::is_empty_unchecked(l))
        .collect()
}

/// Pure core of `done`: flip the first OPEN `## Focus` task whose normalised text contains
/// `query` (already lower-cased) from `[ ]` to `[x]`. Only the authored region is scanned —
/// the walk stops at the next H2 or the [`md::ROLLUP_START`] sentinel, so a mirrored job task
/// is never ticked here. Returns `(new_content, closed_line)`, or `None` when nothing matches.
fn close_first(content: &str, query: &str) -> Option<(String, String)> {
    let mut out: Vec<String> = Vec::new();
    let mut in_focus = false;
    let mut closed: Option<String> = None;
    for line in content.lines() {
        if closed.is_none() {
            if let Some(rest) = line.strip_prefix("## ") {
                in_focus = rest.trim().eq_ignore_ascii_case("Focus");
            } else if in_focus && line.trim() == md::ROLLUP_START {
                in_focus = false; // authored region only
            } else if in_focus
                && md::is_task(line)
                && !md::is_checked(line)
                && !md::is_empty_unchecked(line)
                && md::task_key(line).contains(query)
            {
                let flipped = line.replacen("- [ ]", "- [x]", 1);
                closed = Some(flipped.clone());
                out.push(flipped);
                continue;
            }
        }
        out.push(line.to_string());
    }
    closed.map(|c| {
        let mut joined = out.join("\n");
        if content.ends_with('\n') && !joined.ends_with('\n') {
            joined.push('\n');
        }
        (joined, c)
    })
}

/// Open Focus tasks with their 1-based file line number and dedup key. The cross-profile
/// cockpit needs the position to JUMP to a task and the key to CLOSE it (`focus done`
/// matches on `md::task_key`). Same open-task filter and authored-region boundary as
/// [`open_focus`] / [`close_first`] — the walk stops at the next H2 or [`md::ROLLUP_START`],
/// so mirrored job tasks are never surfaced.
fn open_focus_positions(content: &str) -> Vec<(usize, String, String)> {
    let mut out = Vec::new();
    let mut in_focus = false;
    for (i, line) in content.lines().enumerate() {
        if let Some(rest) = line.strip_prefix("## ") {
            in_focus = rest.trim().eq_ignore_ascii_case("Focus");
        } else if in_focus && line.trim() == md::ROLLUP_START {
            in_focus = false; // authored region only
        } else if in_focus
            && md::is_task(line)
            && !md::is_checked(line)
            && !md::is_empty_unchecked(line)
        {
            out.push((i + 1, md::task_key(line), line.trim_end().to_string()));
        }
    }
    out
}

/// `notes focus --all` — aggregate every configured profile's open Focus items for the
/// cross-profile cockpit. One TSV row per open task:
/// `profile <TAB> file <TAB> line <TAB> key <TAB> text`. Read-only; the caller closes a
/// task with `notes --profile <profile> focus done "<key>"` and jumps with `file`+`line`.
/// A profile that fails to resolve, or whose today note is absent, is skipped silently —
/// this runs from editor integration, so one broken profile must not abort the rest.
pub fn list_all(_log: &Logger) -> Result<()> {
    for name in config::all_profile_names()? {
        let p = match config::resolve(Some(&name)) {
            Ok(p) => p,
            Err(_) => continue,
        };
        let note = daily::today_path(&p);
        if !note.exists() {
            continue;
        }
        let content = fs::read_to_string(&note)?;
        let file = note.display();
        for (line, key, text) in open_focus_positions(&content) {
            println!("{name}\t{file}\t{line}\t{key}\t{text}");
        }
    }
    Ok(())
}

/// `notes focus` / `notes focus list` — today's open cockpit items, one per line.
pub fn list(p: &Profile, _log: &Logger) -> Result<()> {
    let note = daily::today_path(p);
    let items = if note.exists() {
        open_focus(&fs::read_to_string(&note)?)
    } else {
        Vec::new()
    };
    if items.is_empty() {
        println!("focus clear — add one: notes focus add \"<a couple words>\"");
        return Ok(());
    }
    for l in &items {
        println!("{l}");
    }
    Ok(())
}

/// `notes focus add <text>` — append a new open task under today's `## Focus`, stamped
/// `(0d) <!-- since:today -->` like every other daily item. Bootstraps today's note first
/// when absent (idempotent `notes today`), so the section always exists to insert under.
pub fn add(p: &Profile, log: &Logger, text: &str) -> Result<()> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text — a couple words)");
    }
    let note = daily::today_path(p);
    if !note.exists() {
        daily::run(p, log)?; // create today's note + `## Focus` (carry-forward, refs, etc.)
    }
    let today = Local::now().date_naive();
    let line = md::stamp_line(&format!("- [ ] {text}"), today, today);
    let content = fs::read_to_string(&note)?;
    let new_content = md::insert_under_heading(&content, "Focus", std::slice::from_ref(&line));
    fs::write(&note, new_content)?;
    log.info("focus", &format!("added to {}", note.display()));
    println!("{line}");
    Ok(())
}

/// `notes focus done <query>` — check off the first OPEN task under today's `## Focus`
/// whose normalised text contains `<query>` (case-insensitive). Reports what was closed,
/// or lists the open items when nothing matches so the caller can retry.
pub fn done(p: &Profile, log: &Logger, query: &str) -> Result<()> {
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
            fs::write(&note, new_content)?;
            log.info("focus", &format!("done in {}", note.display()));
            println!("done {}", closed.trim());
            Ok(())
        }
        None => {
            println!("no open focus item matches '{query}'. Open now:");
            for l in open_focus(&content) {
                println!("  {l}");
            }
            Ok(())
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
        assert_eq!(closed, "- [x] buy backup drive (2d) <!-- since:2026-07-14 -->");
        assert!(out.contains("- [x] buy backup drive"));
        // Only the matched line flips; the other open task stays open.
        assert!(out.contains("    - [ ] admin local ui"));
        // Trailing newline shape is preserved.
        assert!(out.ends_with("after\n"));
    }

    #[test]
    fn close_first_matches_indented_task_by_substring() {
        let (out, closed) = close_first(NOTE, "admin").unwrap();
        assert_eq!(closed, "    - [x] admin local ui (2d) <!-- since:2026-07-13 -->");
        assert!(out.contains("    - [x] admin local ui"));
        // Indentation is preserved when the checkbox flips.
        assert!(out.contains("\n    - [x]"));
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
}
