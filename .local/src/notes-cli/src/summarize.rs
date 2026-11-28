//! `notes summarize` — extract a day's note into the continuous monthly log.
//!
//! Dedup-safe: the continuous log is the source of truth — if it already contains
//! a `### YYYY-MM-DD` entry we skip (unless `--force`). Missing notes and empty
//! extractions WARN loudly instead of failing silently (the old Python bug).

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use anyhow::{Context, Result};
use chrono::{Duration, Local, NaiveDate};
use std::fs;
use std::path::Path;

/// Sections that carry the open task list forward day to day. A summary keeps only the tasks
/// closed that day from these, so an entry says what happened, not what was still open.
const CARRIED: &[&str] = &["Focus", "Carry Over"];

/// (label shown in summary, heading searched in the note)
pub const SECTIONS: &[(&str, &str)] = &[
    ("Focus", "Focus"),
    ("Notes", "Notes"),
    ("Due", "Due"),
    ("Priority", "Priority"),
    ("Fun", "Fun"),
    ("Carry Over", "Carry Over"),
    ("Journal", "Journal"),
    ("Log", "Log"),
];

pub fn run(p: &Profile, log: &Logger, date: Option<&str>, force: bool) -> Result<()> {
    let date = match date {
        Some(s) => NaiveDate::parse_from_str(s, "%Y-%m-%d")
            .with_context(|| format!("invalid --date '{s}' (want YYYY-MM-DD)"))?,
        None => Local::now().date_naive() - Duration::days(1),
    };
    let date_s = date.format("%Y-%m-%d").to_string();
    let note = p.daily.join(format!("{date_s}.md"));

    if !note.exists() {
        log.warn(
            "summarize",
            &format!("no daily note for {date_s} — nothing to summarize"),
        );
        return Ok(());
    }

    let content = fs::read_to_string(&note)?;
    let summary = match build_summary(&content, &date_s) {
        Some(s) => s,
        None => {
            log.warn(
                "summarize",
                &format!("{date_s} has no extractable content (check heading names)"),
            );
            return Ok(());
        }
    };

    let month = &date_s[..7];
    fs::create_dir_all(&p.continuous)?;
    let log_path = p.continuous.join(format!("{month}.md"));
    ensure_header(&log_path, month)?;

    let existing = fs::read_to_string(&log_path).unwrap_or_default();
    if existing.contains(&format!("### {date_s}")) && !force {
        log.info(
            "summarize",
            &format!("{date_s} already present in {}", log_path.display()),
        );
        return Ok(());
    }

    append(&log_path, &summary)?;
    log.info(
        "summarize",
        &format!("appended {date_s} -> {}", log_path.display()),
    );
    Ok(())
}

/// Build the markdown summary block, or `None` if nothing extractable.
pub fn build_summary(content: &str, date_s: &str) -> Option<String> {
    // Drop the link footer first: the last H2 runs to EOF under md::section_span, so without
    // this the `---` + `Backlog: [[...]]` line leaks into whichever section is last.
    let mut body = content.to_string();
    crate::daily::strip_backlog_footer(&mut body);
    let mut out: Vec<String> = vec![format!("### {date_s}")];
    for (label, heading) in SECTIONS {
        let text = md::section_text(&body, heading);
        let text = if CARRIED.contains(heading) {
            text.and_then(|t| closed_tasks(&t))
        } else {
            text
        };
        if let Some(text) = text {
            out.push(format!("**{label}:**"));
            out.push(text);
        }
    }
    if out.len() == 1 {
        return None;
    }
    Some(out.join("\n\n") + "\n\n---\n\n")
}

/// The closed (`- [x]`) task lines of a carried-forward section, or `None` when none closed.
/// Open tasks, in-progress ones, sub-headings and rules are the carried list, not the day.
fn closed_tasks(text: &str) -> Option<String> {
    let kept: Vec<&str> = text.lines().filter(|l| md::is_checked(l)).collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept.join("\n"))
    }
}

fn ensure_header(path: &Path, month: &str) -> Result<()> {
    if path.exists() {
        return Ok(());
    }
    let header = format!("# Continuous Log: {month}\n\nDaily summaries for {month}.\n\n");
    fs::write(path, header)?;
    Ok(())
}

fn append(path: &Path, summary: &str) -> Result<()> {
    use std::io::Write;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    f.write_all(summary.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_drops_the_link_footer_from_the_last_section() {
        let note = "# 2026-09-29\n\n## Focus\n- [x] shipped it\n\n## Notes\nhello\n\n---\nBacklog: [[journal/backlogs/fun]] · Knowledge: [[journal/index/moc]]\n";
        let s = build_summary(note, "2026-09-29").unwrap();
        assert!(s.contains("- [x] shipped it"), "{s}");
        assert!(s.contains("hello"), "{s}");
        assert!(
            !s.contains("Backlog:"),
            "footer leaked into the summary:\n{s}"
        );
    }

    #[test]
    fn summary_extracts_sections() {
        let note = "# 2026-06-03\n\n## Focus\n- [x] did a thing\n\n## Notes\nhello\n";
        let s = build_summary(note, "2026-06-03").unwrap();
        assert!(s.starts_with("### 2026-06-03"));
        assert!(s.contains("**Focus:**"));
        assert!(s.contains("- [x] did a thing"));
        assert!(s.contains("**Notes:**"));
        assert!(s.trim_end().ends_with("---"));
    }

    #[test]
    fn summary_keeps_closed_focus_tasks_and_drops_the_open_list() {
        let note = "# 2026-11-02\n\n## Focus\n### Urgent\n- [ ] carried open\n- [/] carried in progress\n    - [ ] nested open\n\n### Done\n- [x] closed today\n\n## Notes\nwrote this\n";
        let s = build_summary(note, "2026-11-02").unwrap();
        assert!(s.contains("- [x] closed today"), "{s}");
        assert!(s.contains("wrote this"), "{s}");
        for open in [
            "carried open",
            "carried in progress",
            "nested open",
            "### Urgent",
        ] {
            assert!(
                !s.contains(open),
                "open Focus content leaked ({open}):\n{s}"
            );
        }
    }

    #[test]
    fn summary_treats_carry_over_like_focus() {
        let note = "# 2026-06-01\n\n## Carry Over\n- [ ] still open (21d)\n- [x] finished\n";
        let s = build_summary(note, "2026-06-01").unwrap();
        assert!(
            s.contains("**Carry Over:**") && s.contains("- [x] finished"),
            "{s}"
        );
        assert!(!s.contains("still open"), "{s}");
    }

    #[test]
    fn summary_skips_a_focus_with_nothing_closed() {
        let note = "# 2026-11-03\n\n## Focus\n- [ ] carried\n\n## Notes\nhello\n";
        let s = build_summary(note, "2026-11-03").unwrap();
        assert!(!s.contains("**Focus:**"), "{s}");
        assert!(s.contains("hello"), "{s}");
    }

    #[test]
    fn summary_none_when_only_open_tasks() {
        let note = "# 2026-06-03\n\n## Focus\n- [ ] carried\n";
        assert!(build_summary(note, "2026-06-03").is_none());
    }

    #[test]
    fn summary_none_when_empty() {
        let note = "# 2026-06-03\n\n## Focus\n- [ ] \n";
        assert!(build_summary(note, "2026-06-03").is_none());
    }
}
