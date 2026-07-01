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
    let mut out: Vec<String> = vec![format!("### {date_s}")];
    for (label, heading) in SECTIONS {
        if let Some(text) = md::section_text(content, heading) {
            out.push(format!("**{label}:**"));
            out.push(text);
        }
    }
    if out.len() == 1 {
        return None;
    }
    Some(out.join("\n\n") + "\n\n---\n\n")
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
    let mut f = fs::OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(summary.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_extracts_sections() {
        let note = "# 2026-06-03\n\n## Focus\n- did a thing\n\n## Notes\nhello\n";
        let s = build_summary(note, "2026-06-03").unwrap();
        assert!(s.starts_with("### 2026-06-03"));
        assert!(s.contains("**Focus:**"));
        assert!(s.contains("- did a thing"));
        assert!(s.contains("**Notes:**"));
        assert!(s.trim_end().ends_with("---"));
    }

    #[test]
    fn summary_none_when_empty() {
        let note = "# 2026-06-03\n\n## Focus\n- [ ] \n";
        assert!(build_summary(note, "2026-06-03").is_none());
    }
}
