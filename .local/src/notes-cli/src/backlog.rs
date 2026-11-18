//! `notes backlog [name]`: tidy a standing list and print its path (for editor integration).
//! Tidying = sweep checked items into `## Done`, stamped `#dYYMMDD`, and restamp the rest.
//!
//! The backlog is the list with no time trigger. A task enters it with a `#bYYMMDD` stamp, the
//! day it arrived (`notes backlog --add`, behind nvim's `<leader>tb`), and [`stale`] hands it
//! back to Focus at `#low` once it has sat there [`MAX_DAYS`], so a someday list cannot bury it.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use chrono::{Local, NaiveDate};
use std::collections::HashSet;
use std::fs;
use std::io::Read;

/// How long a task sits in the backlog before `notes today` returns it to Focus.
pub const MAX_DAYS: i64 = 90;

/// The description line a new backlog file is created with.
pub const DESC: &str =
    "Tasks with no date. `<leader>tb` files one here; one left 90 days returns to Focus at #low.";

pub fn run(p: &Profile, log: &Logger, name: &str, add: bool) -> Result<()> {
    let file = match name {
        "backlog" => &p.backlog,
        // `carryover`/`carry` name the file that became scheduled.md.
        "scheduled" | "carryover" | "carry" => &p.scheduled,
        "recurring" => &p.recurring,
        other => bail!("unknown backlog '{other}' (want: backlog | scheduled | recurring)"),
    };
    if add && name != "backlog" {
        bail!("--add files into the backlog only, not '{name}'");
    }
    if name == "backlog" {
        crate::daily::migrate_fun(p, log)?;
    }

    if !file.exists() {
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent)?;
        }
        let (title, tags, desc) = match name {
            "backlog" => ("Backlog", "backlog", DESC),
            "recurring" => ("Recurring", "backlog, recurring","Standing habits: a task with an `(every:…)` token surfaces into a daily note's Due each matching day. Cadences: every:fri · every:mon,thu · every:weekday · every:day · every:1st · every:last."),
            _ => ("Scheduled", "backlog, scheduled", "Holding pen for future-dated tasks — they surface in a daily note's Due section near their date."),
        };
        fs::write(
            file,
            format!("---\ntags: [{tags}]\n---\n\n# {title}\n\n{desc}\n\n## Active\n\n## Done\n"),
        )?;
    }

    // The recurring master is never checked off, so sweeping checked to Done would be wrong,
    // so just ensure it exists and print its path (for editor integration).
    if name == "recurring" {
        println!("{}", file.display());
        return Ok(());
    }

    let mut input = String::new();
    if add {
        std::io::stdin().read_to_string(&mut input)?;
    }
    let _lock = lock(p)?;
    let content = fs::read_to_string(file)?;
    let today = Local::now().date_naive();
    let mut updated = sweep(&content, today);
    if add {
        let (with_new, n) = add_lines(&updated, &input, today)?;
        updated = with_new;
        if n > 0 {
            log.info(
                "backlog",
                &format!("filed {n} task(s) into {}", file.display()),
            );
        }
    }
    if updated != content {
        md::write_atomic(file, &updated)?;
        log.info("backlog", &format!("tidied {}", file.display()));
    }

    println!("{}", file.display());
    Ok(())
}

/// The lock every read-modify-write of the backlog holds (`notes backlog`, `notes today`), so a
/// `<leader>tb` filing and the daily rollover never each write over the other's change.
pub(crate) fn lock(p: &Profile) -> Result<md::FileLock> {
    md::lock_file(&p.state_dir.join("backlog.lock"))
}

/// `content` with the task blocks in `input` filed at the top of `## Active`, each task stamped
/// with today's backlog tag, plus how many tasks went in. A block is a task and the lines indented
/// under it; it may come from any depth (a subtask), so the input is dedented first. A task the
/// backlog already holds is skipped with its block: it is already where the caller sent it.
/// Input with no task, or with a line of prose outside a task's block, is refused whole, because
/// the editor deletes what it sent once this succeeds.
pub fn add_lines(content: &str, input: &str, today: NaiveDate) -> Result<(String, usize)> {
    // Only `## Active`: a finished copy under `## Done` is not the task being sent.
    let mut seen: HashSet<String> = md::section_lines(content, "Active")
        .unwrap_or_default()
        .iter()
        .filter(|l| md::is_task(l))
        .map(|l| md::task_key(l))
        .collect();
    let mut new = Vec::new();
    let mut keep = false;
    let (mut tasks, mut filed) = (0, 0);
    for line in md::dedent(input).lines() {
        if line.trim().is_empty() {
            continue;
        }
        if line.starts_with(char::is_whitespace) && tasks > 0 {
            if keep {
                new.push(line.to_string());
            }
            continue;
        }
        if !md::is_task(line) {
            bail!("not a task, nothing filed: {}", line.trim());
        }
        tasks += 1;
        keep = seen.insert(md::task_key(line));
        if keep {
            new.push(stamp(line.trim_start(), today));
            filed += 1;
        }
    }
    if tasks == 0 {
        bail!("no task on stdin");
    }
    if new.is_empty() {
        return Ok((content.to_string(), 0));
    }
    Ok((md::insert_under_heading(content, "Active", &new), filed))
}

/// `line` carrying exactly one backlog tag, for `date`, ahead of its priority tag.
fn stamp(line: &str, date: NaiveDate) -> String {
    md::normalize_tags(&md::add_tag(
        &md::split_backlog(line).0,
        &md::backlog_tag(date),
    ))
}

/// The open `## Active` tasks that entered the backlog [`MAX_DAYS`] or more before `today`,
/// with the lines indented under them, rewritten for Focus at `#low` with the backlog tag gone;
/// and the backlog without them. An open task with no backlog tag is stamped `today`, so the
/// clock starts the first time it is seen: a task typed in by hand returns like any other.
pub fn stale(content: &str, today: NaiveDate) -> (Vec<String>, String) {
    let mut returned = Vec::new();
    let mut out: Vec<String> = Vec::new();
    let mut in_active = false;
    let mut leaving = false; // the task above is returning, so the lines under it go too
    for line in content.lines() {
        if leaving && line.starts_with(char::is_whitespace) && !line.trim().is_empty() {
            returned.push(line.to_string());
            continue;
        }
        leaving = false;
        if let Some(rest) = line.strip_prefix("## ") {
            in_active = rest.trim().eq_ignore_ascii_case("Active");
        } else if in_active
            && md::is_task(line)
            && !md::is_checked(line)
            && !line.starts_with(char::is_whitespace)
        {
            match md::split_backlog(line) {
                (bare, Some(since)) if (today - since).num_days() >= MAX_DAYS => {
                    let low = md::add_tag(&md::strip_priority_tag(&bare), "#low");
                    returned.push(md::stamp_line(&low, today, today));
                    leaving = true;
                    continue;
                }
                (_, None) => {
                    out.push(stamp(line, today));
                    continue;
                }
                _ => {}
            }
        }
        out.push(line.to_string());
    }
    let mut rest = out.join("\n");
    if content.ends_with('\n') && !rest.ends_with('\n') {
        rest.push('\n');
    }
    (returned, rest)
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
        } else if md::is_task(line) && md::find_since(line, today).is_some() {
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

fn ensure_done_stamp(line: &str, today: NaiveDate) -> String {
    if md::has_done_tag(line) {
        line.trim_end().to_string()
    } else {
        md::add_tag(line, &md::done_tag(today))
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
        let c = "# Backlog\n\n## Active\n- [ ] keep me (1d) <!-- since:2026-06-02 -->\n- [x] finished\n\n## Done\n- [x] old #d260501\n";
        let out = sweep(c, d("2026-06-05"));
        // active keeps the unchecked item, restamped
        assert!(out.contains("- [ ] keep me #c0602"));
        // checked item moved under Done with a done stamp
        assert!(out.contains("- [x] finished #d260605"));
        // existing done preserved
        assert!(out.contains("- [x] old #d260501"));
        // a line already stamped is not stamped twice
        assert_eq!(
            ensure_done_stamp("- [x] a #d260501", d("2026-06-05")),
            "- [x] a #d260501"
        );
        // the tag goes before a trailing marker, as add_tag places every tag
        assert_eq!(md::task_text("- [x] finished #d260605"), "finished");
        assert_eq!(
            ensure_done_stamp("- [x] b <!-- id:x-1 -->", d("2026-06-05")),
            "- [x] b #d260605 <!-- id:x-1 -->"
        );
        // only one ## Done heading
        assert_eq!(out.matches("## Done").count(), 1);
        // finished no longer in the active region (before ## Done)
        let active_region = &out[..out.find("## Done").unwrap()];
        assert!(!active_region.contains("finished"));
    }

    const FILE: &str = "# Backlog\n\n## Active\n- [ ] old one #b260801 #c0801 #low\n- [ ] kept #b261101 #high\n\n## Done\n- [x] gone #b250101 #d250301\n";

    #[test]
    fn add_stamps_dedents_keeps_children_and_skips_duplicates() {
        let today = d("2026-11-18");
        let input =
            "    - [ ] drone setup #c1110 #high\n      - [ ] print one\n    - [ ] kept #c1101\n";
        let (out, n) = add_lines(FILE, input, today).unwrap();
        assert_eq!(n, 1, "{out}");
        assert!(
            out.contains("## Active\n- [ ] drone setup #c1110 #b261118 #high\n  - [ ] print one\n- [ ] old one"),
            "{out}"
        );
        assert_eq!(out.matches("kept").count(), 1, "{out}");
        // Only duplicates: nothing to write, and still a success, since the task is already here.
        assert_eq!(
            add_lines(FILE, "- [ ] kept\n", today).unwrap(),
            (FILE.to_string(), 0)
        );
        // A finished copy under Done is no reason to skip: the editor would delete the new one.
        let done = "## Active\n\n## Done\n- [x] buy filament #d260301\n";
        let (out, n) = add_lines(done, "- [ ] buy filament\n", today).unwrap();
        assert_eq!(n, 1, "{out}");
        assert!(
            out.contains("## Active\n- [ ] buy filament #b261118"),
            "{out}"
        );
        // A task re-filed from Focus with an old stamp takes today's.
        let (out, _) = add_lines("## Active\n", "- [ ] back again #b260101\n", today).unwrap();
        assert!(out.contains("- [ ] back again #b261118"), "{out}");
    }

    #[test]
    fn add_refuses_prose_whole_so_the_editor_deletes_nothing() {
        let today = d("2026-11-18");
        assert!(add_lines(FILE, "- [ ] a task\nsome prose\n", today).is_err());
        assert!(add_lines(FILE, "## Focus\n", today).is_err());
        assert!(add_lines(FILE, "\n\n", today).is_err());
        // Prose indented under a task is that task's note, and travels with it.
        let (out, n) = add_lines(FILE, "- [ ] a task\n  why it matters\n", today).unwrap();
        assert_eq!(n, 1);
        assert!(
            out.contains("- [ ] a task #b261118\n  why it matters\n"),
            "{out}"
        );
    }

    #[test]
    fn stale_returns_a_task_after_max_days_at_low() {
        let file = "## Active\n- [ ] old one #b260801 #c0801 #high\n  note under it\n- [ ] kept #b261101\n- [ ] typed by hand\n\n## Done\n- [x] gone #b250101 #d250301\n";
        let (back, rest) = stale(file, d("2026-11-18"));
        assert_eq!(back, vec!["- [ ] old one #c0801 #low", "  note under it"]);
        assert_eq!(
            rest,
            "## Active\n- [ ] kept #b261101\n- [ ] typed by hand #b261118\n\n## Done\n- [x] gone #b250101 #d250301\n"
        );
        // Day 89 stays; day 90 returns.
        let (back, _) = stale("## Active\n- [ ] x #b260821\n", d("2026-11-18"));
        assert!(back.is_empty(), "{back:?}");
        let (back, _) = stale("## Active\n- [ ] x #b260820\n", d("2026-11-18"));
        assert_eq!(back, vec!["- [ ] x #c1118 #low"]);
    }

    #[test]
    fn the_backlog_tag_is_a_stamp_not_text() {
        assert_eq!(
            md::task_key("- [ ] a #b261118 #low"),
            md::task_key("- [ ] a")
        );
        assert!(md::is_backlog_tag("b261118"));
        assert!(!md::is_backlog_tag("b1118"));
        assert!(!md::is_backlog_tag("backlog"));
    }
}
