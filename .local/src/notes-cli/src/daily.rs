//! `notes today` — idempotent daily-note creation with carry-forward.
//!
//! New model: only fresh **Focus** + **Priority** live inline.
//!   - Priority items carry forward, day-stamped.
//!   - Yesterday's unfinished **Focus** items roll into the `carryover` backlog
//!     (not into today's note), so today's Focus starts clean.
//!   - **Fun** + **Carry Over** are standing backlog files, linked at the bottom.

use crate::config::{self, Profile};
use crate::logging::Logger;
use crate::md;
use anyhow::{Context, Result};
use chrono::{Local, NaiveDate};
use std::fs;
use std::path::{Path, PathBuf};

pub fn today_path(p: &Profile) -> PathBuf {
    let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
    p.daily.join(format!("{today}.md"))
}

/// Today's refs subdirectory for this profile (`<refs>/<YYYY-MM-DD>`).
pub fn today_refs_dir(p: &Profile) -> PathBuf {
    let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
    p.refs.join(today)
}

/// Resolve a named profile path for editor/shell integration (`notes path <target>`).
/// This is the single source of truth that nvim, the `ref`/`refs` aliases, and the
/// smug hub window all consume — so no consumer hardcodes a vault path. Returns
/// `None` for an unknown target so the caller can report it.
pub fn resolve_path(p: &Profile, target: &str) -> Option<PathBuf> {
    Some(match target {
        "daily" => today_path(p),
        "daily-dir" => p.daily.clone(),
        "refs" => p.refs.clone(),
        "refs-today" => today_refs_dir(p),
        "root" => p.root.clone(),
        "fun" => p.fun.clone(),
        "carryover" => p.carryover.clone(),
        "zettel" => p.zettel.clone(),
        "index" => p.index.clone(),
        _ => return None,
    })
}

pub fn run(p: &Profile, log: &Logger) -> Result<()> {
    let today = Local::now().date_naive();
    fs::create_dir_all(&p.daily)
        .with_context(|| format!("creating daily dir {}", p.daily.display()))?;
    ensure_backlogs(p, log)?;

    let note = today_path(p);
    if note.exists() {
        log.info("today", &format!("exists {}", note.display()));
    } else {
        create_note(p, log, today, &note)?;
        log.info("today", &format!("created {}", note.display()));
    }

    link_refs(p, log)?;
    ensure_footer(p, &note)?;
    Ok(())
}

fn create_note(p: &Profile, log: &Logger, today: NaiveDate, note: &Path) -> Result<()> {
    let today_s = today.format("%Y-%m-%d").to_string();

    let mut priority = String::new();
    let mut projects = String::new();
    let mut focus_carry: Vec<String> = Vec::new();

    if let Some(prev) = latest_prev(&p.daily, &today_s)? {
        let prev_date = file_date(&prev).unwrap_or(today);
        let content = fs::read_to_string(&prev)
            .with_context(|| format!("reading previous note {}", prev.display()))?;

        if let Some(lines) = md::section_lines(&content, "Priority") {
            priority = carry(&lines, today, prev_date);
        }
        if let Some(lines) = md::section_lines(&content, "Current Projects") {
            projects = lines.join("\n");
        }
        if let Some(lines) = md::section_lines(&content, "Focus") {
            focus_carry = lines
                .iter()
                .filter(|l| md::is_task(l) && !md::is_checked(l) && !md::is_empty_unchecked(l))
                .map(|l| md::stamp_line(l, today, prev_date))
                .collect();
        }
    }

    // No prior Current Projects to carry forward → auto-discover from the configured
    // `projects` dir (e.g. lab/projects/current). Carry-forward wins so hand-curated
    // wikilinks are preserved; discovery only seeds an otherwise-empty section.
    if projects.trim().is_empty() {
        projects = discover_projects(p);
    }

    let mut s = String::new();
    s.push_str("---\n");
    s.push_str(&format!("date: {today_s}\n"));
    s.push_str("tags: [daily]\n");
    s.push_str("---\n\n");
    s.push_str(&format!("# {today_s}\n\n"));
    s.push_str("## Current Projects\n");
    if !projects.is_empty() {
        s.push_str(&projects);
        s.push('\n');
    }
    s.push_str("\n## Focus\n- [ ] \n\n");
    s.push_str("## Notes\n\n");
    s.push_str("## Priority\n");
    if !priority.is_empty() {
        s.push_str(&priority);
        s.push('\n');
    }
    s.push('\n');

    fs::write(note, s).with_context(|| format!("writing {}", note.display()))?;

    if !focus_carry.is_empty() {
        let n = append_to_carryover(p, &focus_carry)?;
        if n > 0 {
            log.info(
                "today",
                &format!("rolled {n} unfinished Focus item(s) into carryover backlog"),
            );
        }
    }
    Ok(())
}

/// Discover active projects from the configured `projects` dir (e.g. lab/projects/current):
/// one wikilink per immediate subdir that contains a `summary.md`, sorted by name. Subdirs
/// whose name starts with `_` (e.g. `_index`) are skipped. Returns "" when no `projects`
/// dir is configured or it has no qualifying entries.
fn discover_projects(p: &Profile) -> String {
    let Some(dir) = p.projects.as_ref() else {
        return String::new();
    };
    if !dir.is_dir() {
        return String::new();
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return String::new();
    };
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let summary = path.join("summary.md");
        if !path.is_dir() || !summary.exists() {
            continue;
        }
        match path.file_name().and_then(|n| n.to_str()) {
            Some(name) if !name.starts_with('_') => found.push((name.to_string(), summary)),
            _ => {}
        }
    }
    found.sort_by(|a, b| a.0.cmp(&b.0));
    found
        .iter()
        .map(|(name, summary)| format!("- [[{}|{}]]", config::wikilink(&p.root, summary), name))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Drop checked + empty items; day-stamp the rest. Non-task lines pass through.
fn carry(lines: &[String], today: NaiveDate, prev_date: NaiveDate) -> String {
    lines
        .iter()
        .filter_map(|l| {
            if md::is_checked(l) || md::is_empty_unchecked(l) {
                None
            } else if md::is_task(l) {
                Some(md::stamp_line(l, today, prev_date))
            } else {
                Some(l.clone())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn latest_prev(dir: &Path, today_s: &str) -> Result<Option<PathBuf>> {
    if !dir.exists() {
        return Ok(None);
    }
    let mut dates: Vec<PathBuf> = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
            if path.extension().and_then(|e| e.to_str()) == Some("md")
                && is_date(stem)
                && stem != today_s
            {
                dates.push(path);
            }
        }
    }
    dates.sort();
    Ok(dates.pop())
}

fn is_date(s: &str) -> bool {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").is_ok()
}

fn file_date(path: &Path) -> Option<NaiveDate> {
    let stem = path.file_stem()?.to_str()?;
    NaiveDate::parse_from_str(stem, "%Y-%m-%d").ok()
}

/// Append unfinished Focus items to the carryover backlog's `## Active`, deduped.
fn append_to_carryover(p: &Profile, items: &[String]) -> Result<usize> {
    let content = fs::read_to_string(&p.carryover).unwrap_or_default();
    let mut existing: std::collections::HashSet<String> = content
        .lines()
        .filter(|l| md::is_task(l))
        .map(md::task_key)
        .collect();

    let fresh: Vec<String> = items
        .iter()
        .filter(|l| existing.insert(md::task_key(l)))
        .cloned()
        .collect();
    if fresh.is_empty() {
        return Ok(0);
    }
    let updated = md::insert_under_heading(&content, "Active", &fresh);
    fs::write(&p.carryover, updated)?;
    Ok(fresh.len())
}

/// Link today's ref files into the note's `## Refs` section (idempotent).
pub fn link_refs(p: &Profile, log: &Logger) -> Result<()> {
    let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
    let note = p.daily.join(format!("{today}.md"));
    let refs_dir = p.refs.join(&today);
    if !note.exists() || !refs_dir.exists() {
        return Ok(());
    }

    let mut names: Vec<String> = Vec::new();
    for entry in fs::read_dir(&refs_dir)? {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) == Some("md") {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                if stem != "_index" {
                    names.push(stem.to_string());
                }
            }
        }
    }
    if names.is_empty() {
        return Ok(());
    }
    names.sort();

    let mut content = fs::read_to_string(&note)?;
    let links: Vec<String> = names
        .iter()
        .map(|n| format!("- [[{}/{}/{}]]", p.refs_rel, today, n))
        .filter(|link| !content.contains(link.trim_start_matches("- ")))
        .collect();
    if links.is_empty() {
        return Ok(());
    }

    if content.contains("## Refs") {
        content = md::insert_under_heading(&content, "Refs", &links);
    } else {
        let mut block = String::from("\n## Refs\n");
        for l in &links {
            block.push_str(l);
            block.push('\n');
        }
        // keep Refs above any trailing footer
        content = insert_before_footer(&content, &block);
    }
    fs::write(&note, content)?;
    log.info("link-refs", &format!("linked {} ref(s)", links.len()));
    Ok(())
}

/// Add the backlog footer if not already present.
fn ensure_footer(p: &Profile, note: &Path) -> Result<()> {
    let mut content = fs::read_to_string(note)?;
    if content.contains("Backlogs:") {
        return Ok(());
    }
    let fun = config::wikilink(&p.root, &p.fun);
    let carry = config::wikilink(&p.root, &p.carryover);
    if !content.ends_with('\n') {
        content.push('\n');
    }
    content.push_str(&format!("\n---\nBacklogs: [[{fun}]] · [[{carry}]]\n"));
    fs::write(note, content)?;
    Ok(())
}

fn insert_before_footer(content: &str, block: &str) -> String {
    if let Some(idx) = content.find("\n---\nBacklogs:") {
        let (head, tail) = content.split_at(idx);
        format!("{}{}{}", head.trim_end(), block, tail)
    } else {
        format!("{}{}", content.trim_end(), block)
    }
}

/// Create the standing backlog files from templates if missing.
fn ensure_backlogs(p: &Profile, log: &Logger) -> Result<()> {
    ensure_backlog_file(
        &p.fun,
        "Fun",
        "fun",
        "Standing backlog of fun / personal / creative tasks.",
        log,
    )?;
    ensure_backlog_file(
        &p.carryover,
        "Carry Over",
        "carryover",
        "Triage queue: unfinished items roll here from daily Focus.",
        log,
    )?;
    Ok(())
}

fn ensure_backlog_file(path: &Path, title: &str, tag: &str, desc: &str, log: &Logger) -> Result<()> {
    if path.exists() {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let body = format!(
        "---\ntags: [backlog, {tag}]\n---\n\n# {title}\n\n{desc} Linked from daily notes.\n\n## Active\n\n## Done\n"
    );
    fs::write(path, body)?;
    log.info("backlog", &format!("created {}", path.display()));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(root: &str) -> Profile {
        let r = PathBuf::from(root);
        Profile {
            name: "test".into(),
            source: "test".into(),
            root: r.clone(),
            daily: r.join("journal/daily"),
            refs: r.join("journal/refs"),
            refs_rel: "journal/refs".into(),
            fun: r.join("journal/backlogs/fun.md"),
            carryover: r.join("journal/backlogs/carryover.md"),
            summaries: r.join("journal/summaries"),
            continuous: r.join("journal/summaries/continuous"),
            monthly: r.join("journal/summaries/monthly"),
            archive: r.join("journal/daily_archive"),
            zettel: r.join("journal/permanent"),
            index: r.join("journal/index"),
            projects: None,
            state_dir: r.join(".state"),
            log_file: r.join(".state/journal.log"),
        }
    }

    #[test]
    fn resolve_known_targets() {
        let p = profile("/vault");
        assert_eq!(resolve_path(&p, "daily-dir").unwrap(), PathBuf::from("/vault/journal/daily"));
        assert_eq!(resolve_path(&p, "refs").unwrap(), PathBuf::from("/vault/journal/refs"));
        assert_eq!(resolve_path(&p, "root").unwrap(), PathBuf::from("/vault"));
        assert_eq!(resolve_path(&p, "fun").unwrap(), PathBuf::from("/vault/journal/backlogs/fun.md"));
        // refs-today is under refs; daily note is under daily-dir
        assert!(resolve_path(&p, "refs-today").unwrap().starts_with("/vault/journal/refs"));
        assert!(resolve_path(&p, "daily").unwrap().starts_with("/vault/journal/daily"));
        assert!(resolve_path(&p, "daily").unwrap().extension().is_some()); // .md file
    }

    #[test]
    fn resolve_unknown_is_none() {
        let p = profile("/vault");
        assert!(resolve_path(&p, "bogus").is_none());
    }
}
