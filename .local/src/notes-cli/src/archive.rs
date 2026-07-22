//! `notes archive` — roll a month's daily notes into the monthly summary and
//! move the originals into the archive tree. Dedup-safe against the monthly file.

use crate::config::Profile;
use crate::logging::Logger;
use crate::summarize::build_summary;
use anyhow::{Context, Result};
use chrono::{Datelike, Local, NaiveDate};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

pub fn run(
    p: &Profile,
    log: &Logger,
    month: Option<&str>,
    dry_run: bool,
    backfill: bool,
) -> Result<()> {
    let months: Vec<(i32, u32)> = if let Some(m) = month {
        vec![parse_month(m)?]
    } else if backfill {
        months_with_notes(&p.daily)?
    } else {
        vec![previous_month(Local::now().date_naive())]
    };

    if months.is_empty() {
        log.info("archive", "no months to process");
        return Ok(());
    }

    for (y, m) in months {
        process_month(p, log, y, m, dry_run)?;
    }
    Ok(())
}

fn process_month(p: &Profile, log: &Logger, year: i32, month: u32, dry_run: bool) -> Result<()> {
    let month_str = format!("{year:04}-{month:02}");
    let mut notes: Vec<_> = Vec::new();
    if p.daily.exists() {
        for entry in fs::read_dir(&p.daily)? {
            let path = entry?.path();
            if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
                if name.starts_with(&format!("{month_str}-")) && name.ends_with(".md") {
                    notes.push(path);
                }
            }
        }
    }
    notes.sort();
    if notes.is_empty() {
        return Ok(());
    }

    // Build/append monthly summary (dedup by ### date).
    let monthly_dir = p.monthly.join(format!("{year:04}"));
    let monthly_path = monthly_dir.join(format!("{month_str}.md"));
    let existing = fs::read_to_string(&monthly_path).unwrap_or_default();

    let mut appended = 0usize;
    let mut buf = String::new();
    for note in &notes {
        let date_s = note
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if existing.contains(&format!("### {date_s}")) {
            continue;
        }
        let content = fs::read_to_string(note)?;
        if let Some(summary) = build_summary(&content, &date_s) {
            buf.push_str(&summary);
            appended += 1;
        }
    }

    if dry_run {
        println!(
            "[dry-run] {month_str}: would append {appended} summaries to {} and archive {} note(s)",
            monthly_path.display(),
            notes.len()
        );
        return Ok(());
    }

    if appended > 0 {
        fs::create_dir_all(&monthly_dir)?;
        use std::io::Write;
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&monthly_path)?;
        f.write_all(buf.as_bytes())?;
    }

    // Move daily notes into archive/YYYY/YYYY-MM/.
    let archive_dir = p.archive.join(format!("{year:04}")).join(&month_str);
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("creating archive dir {}", archive_dir.display()))?;
    for note in &notes {
        let dest = archive_dir.join(note.file_name().unwrap());
        move_file(note, &dest)?;
    }

    log.info(
        "archive",
        &format!(
            "{month_str}: appended {appended} summaries, archived {} note(s) -> {}",
            notes.len(),
            archive_dir.display()
        ),
    );
    Ok(())
}

/// Rename, falling back to copy+remove across filesystem boundaries.
fn move_file(src: &Path, dest: &Path) -> Result<()> {
    if fs::rename(src, dest).is_ok() {
        return Ok(());
    }
    fs::copy(src, dest)?;
    fs::remove_file(src)?;
    Ok(())
}

fn parse_month(s: &str) -> Result<(i32, u32)> {
    let date = NaiveDate::parse_from_str(&format!("{s}-01"), "%Y-%m-%d")
        .with_context(|| format!("invalid --month '{s}' (want YYYY-MM)"))?;
    Ok((date.year(), date.month()))
}

fn previous_month(d: NaiveDate) -> (i32, u32) {
    if d.month() == 1 {
        (d.year() - 1, 12)
    } else {
        (d.year(), d.month() - 1)
    }
}

fn months_with_notes(daily: &Path) -> Result<Vec<(i32, u32)>> {
    let mut set: BTreeSet<(i32, u32)> = BTreeSet::new();
    if daily.exists() {
        for entry in fs::read_dir(daily)? {
            let path = entry?.path();
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                if let Ok(date) = NaiveDate::parse_from_str(stem, "%Y-%m-%d") {
                    set.insert((date.year(), date.month()));
                }
            }
        }
    }
    let today = Local::now().date_naive();
    set.remove(&(today.year(), today.month())); // never archive the current month
    Ok(set.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn previous_month_wraps_year() {
        assert_eq!(
            previous_month(NaiveDate::from_ymd_opt(2026, 1, 15).unwrap()),
            (2025, 12)
        );
        assert_eq!(
            previous_month(NaiveDate::from_ymd_opt(2026, 6, 3).unwrap()),
            (2026, 5)
        );
    }

    #[test]
    fn parse_month_ok() {
        assert_eq!(parse_month("2026-05").unwrap(), (2026, 5));
        assert!(parse_month("nope").is_err());
    }
}
