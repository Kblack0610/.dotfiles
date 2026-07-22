//! `notes backlog <fun|carryover>` — tidy a standing backlog file and print its
//! path (for editor integration). Tidying = sweep checked items into `## Done`
//! and recompute day-counts on remaining active items.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::{Local, NaiveDate};
use std::fs;
use std::path::{Path, PathBuf};

pub fn run(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let file = match name {
        "fun" => &p.fun,
        // `carryover`/`carry` kept as back-compat aliases — the file moved to scheduled.md.
        "scheduled" | "carryover" | "carry" => &p.scheduled,
        "recurring" => &p.recurring,
        other => bail!("unknown backlog '{other}' (want: fun | scheduled | recurring)"),
    };

    if !file.exists() {
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent)?;
        }
        let (title, tag, desc) = match name {
            "fun" => ("Fun", "fun", "Standing backlog of fun / personal / creative tasks."),
            "recurring" => ("Recurring", "recurring", "Standing habits: a task with an `(every:…)` token surfaces into a daily note's Due each matching day. Cadences: every:fri · every:mon,thu · every:weekday · every:day · every:1st · every:last."),
            _ => ("Scheduled", "scheduled", "Holding pen for future-dated tasks — they surface in a daily note's Due section near their date."),
        };
        fs::write(
            file,
            format!(
                "---\ntags: [backlog, {tag}]\n---\n\n# {title}\n\n{desc}\n\n## Active\n\n## Done\n"
            ),
        )?;
    }

    // The recurring master is never checked off — sweeping checked→Done would be wrong,
    // so just ensure it exists and print its path (for editor integration).
    if name == "recurring" {
        println!("{}", file.display());
        return Ok(());
    }

    let content = fs::read_to_string(file)?;
    let today = Local::now().date_naive();
    let updated = sweep(&content, today);
    if updated != content {
        fs::write(file, updated)?;
        log.info("backlog", &format!("tidied {}", file.display()));
    }

    println!("{}", file.display());
    Ok(())
}

/// Move checked items into the `## Done` section; recompute day-counts on the
/// remaining active items.
fn sweep(content: &str, today: NaiveDate) -> String {
    let mut before: Vec<String> = Vec::new();
    let mut done: Vec<String> = Vec::new();
    let mut moved: Vec<String> = Vec::new();
    let mut in_done = false;

    for line in content.lines() {
        if line.trim() == "## Done" {
            in_done = true;
            continue;
        }
        if in_done {
            if !line.trim().is_empty() {
                done.push(line.to_string());
            }
            continue;
        }
        if md::is_checked(line) {
            moved.push(ensure_done_stamp(line, today));
        } else if md::is_task(line) && md::find_since(line).is_some() {
            // origin_if_new is unused because the line already carries a since: date
            before.push(md::stamp_line(line, today, today));
        } else {
            before.push(line.to_string());
        }
    }

    let mut out = String::new();
    out.push_str(before.join("\n").trim_end());
    out.push_str("\n\n## Done\n");
    for d in done {
        out.push_str(&d);
        out.push('\n');
    }
    for m in moved {
        out.push_str(&m);
        out.push('\n');
    }
    out
}

/// One-time migration: lift the `## Fun` and `## Carry Over` sections out of a
/// daily note and into the standing backlog files. Unchecked items → `## Active`,
/// checked items → `## Done`. Non-destructive (the source note is not modified)
/// and idempotent (skips a backlog whose `## Active` already has content unless
/// `--force`).
pub fn seed(p: &Profile, log: &Logger, from: Option<&str>, force: bool) -> Result<()> {
    let note = match from {
        Some(f) => PathBuf::from(f),
        None => latest_daily(&p.daily)?
            .ok_or_else(|| anyhow::anyhow!("no daily note found to seed from"))?,
    };
    let content =
        fs::read_to_string(&note).with_context(|| format!("reading {}", note.display()))?;
    log.info("seed", &format!("seeding backlogs from {}", note.display()));

    seed_one(
        &p.fun,
        "Fun",
        "fun",
        "Standing backlog of fun / personal / creative tasks.",
        md::section_lines(&content, "Fun").unwrap_or_default(),
        force,
        log,
    )?;
    seed_one(
        &p.carryover,
        "Carry Over",
        "carryover",
        "Triage queue: unfinished items roll here from daily Focus.",
        md::section_lines(&content, "Carry Over").unwrap_or_default(),
        force,
        log,
    )?;
    Ok(())
}

fn seed_one(
    path: &Path,
    title: &str,
    tag: &str,
    desc: &str,
    lines: Vec<String>,
    force: bool,
    log: &Logger,
) -> Result<()> {
    if lines.is_empty() {
        return Ok(());
    }
    // Refuse to clobber an already-populated backlog unless forced.
    if path.exists() {
        let existing = fs::read_to_string(path).unwrap_or_default();
        if let Some(active) = md::section_lines(&existing, "Active") {
            if !active.is_empty() && !force {
                log.warn(
                    "seed",
                    &format!(
                        "{} already has Active items — skipping (use --force)",
                        path.display()
                    ),
                );
                return Ok(());
            }
        }
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let active: Vec<&String> = lines.iter().filter(|l| !md::is_checked(l)).collect();
    let done: Vec<&String> = lines.iter().filter(|l| md::is_checked(l)).collect();

    let mut out = format!("---\ntags: [backlog, {tag}]\n---\n\n# {title}\n\n{desc} Linked from daily notes.\n\n## Active\n");
    for l in &active {
        out.push_str(l);
        out.push('\n');
    }
    out.push_str("\n## Done\n");
    for l in &done {
        out.push_str(l);
        out.push('\n');
    }
    fs::write(path, out)?;
    log.info(
        "seed",
        &format!(
            "wrote {} ({} active, {} done)",
            path.display(),
            active.len(),
            done.len()
        ),
    );
    Ok(())
}

fn latest_daily(dir: &Path) -> Result<Option<PathBuf>> {
    if !dir.exists() {
        return Ok(None);
    }
    let mut dates: Vec<PathBuf> = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
            if path.extension().and_then(|e| e.to_str()) == Some("md")
                && NaiveDate::parse_from_str(stem, "%Y-%m-%d").is_ok()
            {
                dates.push(path);
            }
        }
    }
    dates.sort();
    Ok(dates.pop())
}

fn ensure_done_stamp(line: &str, today: NaiveDate) -> String {
    let l = line.trim_end();
    if l.contains("(done:") {
        l.to_string()
    } else {
        format!("{} (done:{})", l, today.format("%Y-%m-%d"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn sweep_moves_checked_to_done() {
        let c = "# Fun\n\n## Active\n- [ ] keep me (1d) <!-- since:2026-06-02 -->\n- [x] finished\n\n## Done\n- [x] old (done:2026-05-01)\n";
        let out = sweep(c, d("2026-06-05"));
        // active keeps the unchecked item, restamped
        assert!(out.contains("- [ ] keep me (3d) <!-- since:2026-06-02 -->"));
        // checked item moved under Done with a done stamp
        assert!(out.contains("- [x] finished (done:2026-06-05)"));
        // existing done preserved
        assert!(out.contains("- [x] old (done:2026-05-01)"));
        // only one ## Done heading
        assert_eq!(out.matches("## Done").count(), 1);
        // finished no longer in the active region (before ## Done)
        let active_region = &out[..out.find("## Done").unwrap()];
        assert!(!active_region.contains("finished"));
    }
}
