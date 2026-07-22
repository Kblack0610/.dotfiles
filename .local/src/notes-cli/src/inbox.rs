//! `notes inbox` — the capture → triage → drain loop for `~/.notes/inbox`.
//!
//! The inbox holds *dated human/agent captures only* (`/remember` writes
//! `inbox/<date>.md`, `/daily:analysis` writes `inbox/<date>-analysis.md`,
//! and `notes inbox add` appends from the terminal). Telemetry/runtime state
//! never belongs here — that lives under `~/.agent` or the XDG cache.
//!
//! - `list` (default) is the triage view: pending captures oldest-first.
//! - `add` is the capture path from a shell.
//! - `archive` is the drain: move triaged captures into `inbox/_archive/`,
//!   so the active view only ever shows what still needs processing.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Context, Result};
use chrono::{Local, NaiveDate};
use std::fs;
use std::path::{Path, PathBuf};

/// Captures older than this many days are flagged stale in the triage view.
const STALE_DAYS: i64 = 14;
const ARCHIVE_DIR: &str = "_archive";

/// One pending capture in the inbox.
struct Item {
    path: PathBuf,
    /// Date parsed from the filename prefix, if any.
    date: Option<NaiveDate>,
    age_days: i64,
    title: String,
}

/// Parse a leading `YYYY-MM-DD` date from a filename stem (the rest is free text:
/// `2026-06-16`, `2026-06-16-analysis`, `2026-01-16_ghee-sheets_plan`).
fn parse_date_prefix(stem: &str) -> Option<NaiveDate> {
    if stem.len() < 10 {
        return None;
    }
    NaiveDate::parse_from_str(&stem[..10], "%Y-%m-%d").ok()
}

/// A markdown horizontal rule (`---`, `***`, `___`, `- - -`) — never a title.
fn is_hrule(t: &str) -> bool {
    !t.is_empty() && t.chars().all(|c| matches!(c, '-' | '*' | '_' | ' '))
}

/// Best-effort title for the listing: skip YAML frontmatter, then return the
/// first ATX heading (any `#` level), else the first plain line — stripped of
/// leading markers and truncated. Horizontal rules and lines that strip to
/// nothing are skipped (real captures led by a `---` separator gave empty titles).
fn extract_title(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let mut idx = 0;
    // YAML frontmatter only counts when `---` is the very first line.
    if lines.first().map(|l| l.trim()) == Some("---") {
        idx = 1;
        while idx < lines.len() && lines[idx].trim() != "---" {
            idx += 1;
        }
        if idx < lines.len() {
            idx += 1; // consume the closing `---`
        }
    }
    let mut fallback: Option<String> = None;
    for line in lines.iter().skip(idx) {
        let t = line.trim();
        if t.is_empty() || is_hrule(t) {
            continue;
        }
        let is_heading = t.starts_with('#');
        let cleaned = t
            .trim_start_matches('#')
            .trim_start()
            .trim_start_matches(['-', '*'])
            .trim();
        // Drop a trailing HTML comment (e.g. the `<!-- session:… -->` tag) from the title.
        let cleaned = match cleaned.find("<!--") {
            Some(i) => cleaned[..i].trim_end(),
            None => cleaned,
        };
        if cleaned.is_empty() {
            continue;
        }
        if is_heading {
            return truncate(cleaned);
        }
        if fallback.is_none() {
            fallback = Some(truncate(cleaned));
        }
    }
    fallback.unwrap_or_else(|| "(empty)".to_string())
}

fn truncate(s: &str) -> String {
    const MAX: usize = 60;
    if s.chars().count() > MAX {
        let mut t: String = s.chars().take(MAX - 1).collect();
        t.push('…');
        t
    } else {
        s.to_string()
    }
}

/// Files in the inbox top level that count as captures: `*.md`, excluding the
/// archive subdir and dotfiles. Returns items sorted oldest-first (triage order).
fn scan(dir: &Path, today: NaiveDate) -> Result<Vec<Item>> {
    let mut items = Vec::new();
    if !dir.is_dir() {
        return Ok(items);
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if !path.is_file() {
            continue; // skip _archive/ and any other subdirs
        }
        let name = match path.file_name().and_then(|s| s.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if name.starts_with('.') || path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let date = parse_date_prefix(stem);
        let age_days = match date {
            Some(d) => (today - d).num_days().max(0),
            None => mtime_age_days(&path, today),
        };
        let content = fs::read_to_string(&path).unwrap_or_default();
        items.push(Item {
            path,
            date,
            age_days,
            title: extract_title(&content),
        });
    }
    // Oldest first; undated items (age via mtime) interleave by age.
    items.sort_by(|a, b| b.age_days.cmp(&a.age_days).then(a.path.cmp(&b.path)));
    Ok(items)
}

/// Age in whole days from a file's mtime to `today` (fallback for undated files).
fn mtime_age_days(path: &Path, today: NaiveDate) -> i64 {
    let modified = match path.metadata().and_then(|m| m.modified()) {
        Ok(m) => m,
        Err(_) => return 0,
    };
    let dt: chrono::DateTime<Local> = modified.into();
    (today - dt.date_naive()).num_days().max(0)
}

/// `notes inbox` / `notes inbox list` — the triage view.
pub fn list(p: &Profile, _log: &Logger) -> Result<()> {
    let today = Local::now().date_naive();
    let items = scan(&p.inbox, today)?;

    if items.is_empty() {
        println!("inbox clear ✨  ({})", p.inbox.display());
        return Ok(());
    }

    let stale = items.iter().filter(|i| i.age_days >= STALE_DAYS).count();
    println!("inbox — {} pending ({})\n", items.len(), p.inbox.display());
    for it in &items {
        let flag = if it.age_days >= STALE_DAYS { "!" } else { " " };
        let age = match it.date {
            Some(_) => format!("{:>3}d", it.age_days),
            None => format!("~{:>2}d", it.age_days), // ~ = derived from mtime, undated
        };
        let name = it.path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        println!("{flag} {age}  {name:<32}  {}", it.title);
    }
    println!();
    if stale > 0 {
        println!(
            "{stale} stale (≥{STALE_DAYS}d, marked !). Drain triaged items: notes inbox archive <file> | --stale"
        );
    } else {
        println!("Drain triaged items: notes inbox archive <file>");
    }
    Ok(())
}

/// `notes inbox add <text>` — append a timestamped bullet to today's capture
/// file (`inbox/<YYYY-MM-DD>.md`), creating it with a header if new.
pub fn add(p: &Profile, log: &Logger, text: &str) -> Result<()> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide capture text)");
    }
    fs::create_dir_all(&p.inbox)
        .with_context(|| format!("creating inbox dir {}", p.inbox.display()))?;
    let now = Local::now();
    let date = now.date_naive().format("%Y-%m-%d").to_string();
    let file = p.inbox.join(format!("{date}.md"));

    let mut body = if file.exists() {
        fs::read_to_string(&file)?
    } else {
        format!("# Inbox - {date}\n")
    };
    if !body.ends_with('\n') {
        body.push('\n');
    }
    // When captured from inside a Claude Code session, tag the capture with the session
    // id (mirrors the `<!-- since:… -->` marker convention) so it's traceable back to
    // the conversation via `claude -r <id>`. Absent for plain terminal captures.
    let session = std::env::var("CLAUDE_CODE_SESSION_ID")
        .ok()
        .filter(|s| !s.is_empty());
    let marker = session
        .map(|id| format!(" <!-- session:{id} -->"))
        .unwrap_or_default();
    body.push_str(&format!("\n- {} {}{}\n", now.format("%H:%M"), text, marker));
    fs::write(&file, body)?;
    log.info("inbox", &format!("captured to {}", file.display()));
    println!("{}", file.display());
    Ok(())
}

/// `notes inbox archive [target] [--stale] [--before DATE]` — the drain.
/// Move triaged captures into `inbox/_archive/`. Exactly one selector applies:
/// a filename, `--stale` (age ≥ STALE_DAYS), or `--before <YYYY-MM-DD>`.
pub fn archive(
    p: &Profile,
    log: &Logger,
    target: Option<&str>,
    stale: bool,
    before: Option<&str>,
) -> Result<()> {
    let selectors = target.is_some() as u8 + stale as u8 + before.is_some() as u8;
    if selectors != 1 {
        bail!("pick exactly one: a filename, --stale, or --before <YYYY-MM-DD>");
    }
    let today = Local::now().date_naive();
    let archive_dir = p.inbox.join(ARCHIVE_DIR);

    let to_move: Vec<PathBuf> = if let Some(name) = target {
        // Accept a bare filename or a path; resolve against the inbox.
        let candidate = {
            let raw = Path::new(name);
            if raw.is_absolute() {
                raw.to_path_buf()
            } else {
                p.inbox.join(name)
            }
        };
        if !candidate.is_file() {
            bail!("no such inbox capture: {}", candidate.display());
        }
        vec![candidate]
    } else if let Some(date_str) = before {
        let cutoff = NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
            .with_context(|| format!("--before wants YYYY-MM-DD, got '{date_str}'"))?;
        scan(&p.inbox, today)?
            .into_iter()
            .filter(|i| i.date.map(|d| d < cutoff).unwrap_or(false))
            .map(|i| i.path)
            .collect()
    } else {
        scan(&p.inbox, today)?
            .into_iter()
            .filter(|i| i.age_days >= STALE_DAYS)
            .map(|i| i.path)
            .collect()
    };

    if to_move.is_empty() {
        println!("nothing to archive");
        return Ok(());
    }
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("creating {}", archive_dir.display()))?;

    let mut moved = 0;
    for src in &to_move {
        let name = src.file_name().unwrap_or_default();
        let dest = archive_dir.join(name);
        fs::rename(src, &dest)
            .with_context(|| format!("archiving {} → {}", src.display(), dest.display()))?;
        println!("archived {}", name.to_string_lossy());
        moved += 1;
    }
    log.info(
        "inbox",
        &format!("archived {moved} capture(s) to {}", archive_dir.display()),
    );
    Ok(())
}

/// Count of pending (non-archived) captures and how many are stale — for `doctor`.
pub fn backlog_counts(p: &Profile) -> (usize, usize) {
    let today = Local::now().date_naive();
    match scan(&p.inbox, today) {
        Ok(items) => {
            let stale = items.iter().filter(|i| i.age_days >= STALE_DAYS).count();
            (items.len(), stale)
        }
        Err(_) => (0, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_prefix_parses_known_shapes() {
        assert_eq!(
            parse_date_prefix("2026-06-16"),
            NaiveDate::from_ymd_opt(2026, 6, 16)
        );
        assert_eq!(
            parse_date_prefix("2026-06-16-analysis"),
            NaiveDate::from_ymd_opt(2026, 6, 16)
        );
        assert_eq!(
            parse_date_prefix("2026-01-16_ghee-sheets_plan"),
            NaiveDate::from_ymd_opt(2026, 1, 16)
        );
        assert!(parse_date_prefix("notes").is_none());
        assert!(parse_date_prefix("system-h").is_none());
    }

    #[test]
    fn title_prefers_heading_then_first_line() {
        assert_eq!(
            extract_title("# Inbox - 2026-06-16\n\n- a thing"),
            "Inbox - 2026-06-16"
        );
        assert_eq!(extract_title("just a line\nmore"), "just a line");
        assert_eq!(
            extract_title("---\ntags: [x]\n---\n# Real Title\n"),
            "Real Title"
        );
        assert_eq!(extract_title("\n\n"), "(empty)");
    }

    #[test]
    fn title_handles_h2_and_leading_rule() {
        // Real-world shape: blank line, a `---` rule (not frontmatter), then `##`.
        let c = "\n---\n\n## Memory Sync Report (2026-03-03)\n_Source: /remember_\n";
        assert_eq!(extract_title(c), "Memory Sync Report (2026-03-03)");
        // A bare horizontal rule with no real content falls through to (empty).
        assert_eq!(extract_title("---\n***\n"), "(empty)");
        // Hyphens inside a title are preserved (only leading markers stripped).
        assert_eq!(
            extract_title("- 2026-01-17 did a thing"),
            "2026-01-17 did a thing"
        );
    }

    #[test]
    fn title_truncates_long_input() {
        let long = "x".repeat(80);
        let t = extract_title(&long);
        assert_eq!(t.chars().count(), 60);
        assert!(t.ends_with('…'));
    }
}
