//! `notes focus mv` — move a Focus task between profiles and/or re-tag its project.
//!
//! The cockpit groups tasks into sections that map onto two different things: a job
//! section IS a profile (the task lives in that profile's daily note), while a project
//! section is a `<project>:` prefix on a task in the personal note. So "move this task"
//! is one of: change the profile, change the prefix, or both. This does all three.
//!
//! The original `<!-- since -->` origin is carried over, so a moved task keeps its age
//! (`(Nd)`) instead of looking brand new — moving work between lanes doesn't reset how
//! long it has been open. The destination is written BEFORE the source removal, so a
//! failed write can never lose the task.
//!
//! Lives in its own module (rather than `focus.rs`) purely to stay out of the way of a
//! concurrent refactor there.

use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use chrono::Local;
use std::fs;

/// Priority hashtags the daily-note convention keeps pinned at the end of a task line.
const PRIORITIES: [&str; 4] = ["#urgent", "#high", "#medium", "#low"];

/// The human text of a task line — checkbox, `(Nd)` day-count, `<!-- since -->` comment
/// and a trailing priority tag stripped — with ORIGINAL CASE preserved (unlike
/// `md::task_key`, which lower-cases for matching). Returns `(text, priority)`.
fn task_text(line: &str) -> (String, Option<String>) {
    let mut t = line.trim().to_string();

    // Priority FIRST: `stamp_line` pins it after the comment (`… <!-- since --> #high`),
    // so truncating at `<!--` before lifting it would silently drop the tag.
    let mut prio = None;
    for p in PRIORITIES {
        if t.ends_with(p) {
            prio = Some(p.to_string());
            t.truncate(t.len() - p.len());
            t = t.trim_end().to_string();
            break;
        }
    }

    if let Some(i) = t.find("<!--") {
        t.truncate(i);
    }
    t = t.trim_end().to_string();

    // trailing `(Nd)` day count
    if let Some(i) = t.rfind('(') {
        let tail = t[i..].to_string();
        if tail.len() > 3
            && tail.ends_with("d)")
            && tail[1..tail.len() - 2].chars().all(|c| c.is_ascii_digit())
        {
            t.truncate(i);
            t = t.trim_end().to_string();
        }
    }

    (strip_checkboxes(&t), prio)
}

/// Strip leading `- [ ]` checkboxes, REPEATEDLY. Hand-edited lines sometimes carry a
/// doubled `- [ ] - [ ] text`, and a leftover inner box renders a moved task as a nested
/// checkbox. Applied both to the raw line and to the text left after a tag is removed
/// (a doubled box can hide behind the tag: `- [ ] proj: - [ ] text`).
fn strip_checkboxes(s: &str) -> String {
    let mut t = s.trim_start().to_string();
    while let Some(rest) = t
        .strip_prefix("- [ ]")
        .or_else(|| t.strip_prefix("- [x]"))
        .or_else(|| t.strip_prefix("- [X]"))
        .or_else(|| t.strip_prefix("- [/]"))
    {
        t = rest.trim_start().to_string();
    }
    t.trim().to_string()
}

/// True when `head` looks like a project tag rather than part of a sentence or a URL
/// scheme — a single bare word, so `pmp:` tags but `screen 2 orange:` and `https:` don't.
fn is_tag_head(head: &str) -> bool {
    !head.is_empty()
        && head
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        && !head.eq_ignore_ascii_case("http")
        && !head.eq_ignore_ascii_case("https")
}

/// Add, swap, or remove a leading `<tag>:` project prefix, leaving the rest of the text
/// untouched. `tag = None` removes any existing prefix.
fn retag(text: &str, tag: Option<&str>) -> String {
    let stripped = match text.split_once(':') {
        // a doubled checkbox can hide behind the tag (`proj: - [ ] text`) — clean it too
        Some((head, rest)) if is_tag_head(head) => strip_checkboxes(rest),
        _ => text.to_string(),
    };
    match tag {
        Some(t) => format!("{}: {}", t.trim(), stripped),
        None => stripped,
    }
}

/// Remove the first OPEN `## Focus` task whose normalised text contains `query`,
/// returning `(content_without_it, the_removed_line)`. Only the authored region is
/// scanned — the walk stops at the next H2 or [`md::ROLLUP_START`], so a mirrored job
/// task is never moved out from under its owning profile.
fn take_first(content: &str, query: &str) -> Option<(String, String)> {
    let mut out: Vec<String> = Vec::new();
    let mut in_focus = false;
    let mut taken: Option<String> = None;
    for line in content.lines() {
        if taken.is_none() {
            if let Some(rest) = line.strip_prefix("## ") {
                in_focus = rest.trim().eq_ignore_ascii_case("Focus");
            } else if in_focus && line.trim() == md::ROLLUP_START {
                in_focus = false;
            } else if in_focus
                && md::is_task(line)
                && !md::is_checked(line)
                && !md::is_empty_unchecked(line)
                && md::task_key(line).contains(query)
            {
                taken = Some(line.to_string());
                continue;
            }
        }
        out.push(line.to_string());
    }
    taken.map(|line| {
        let mut joined = out.join("\n");
        if content.ends_with('\n') && !joined.ends_with('\n') {
            joined.push('\n');
        }
        (joined, line)
    })
}

/// `notes focus mv <query> [--to <profile>] [--tag <project> | --untag]`
pub fn mv(
    p: &Profile,
    log: &Logger,
    query: &str,
    to: Option<&str>,
    tag: Option<&str>,
    untag: bool,
) -> Result<i32> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let src_note = daily::today_path(p);
    if !src_note.exists() {
        bail!("no daily note yet — run: notes today");
    }
    let src_content = fs::read_to_string(&src_note)?;
    let Some((src_without, line)) = take_first(&src_content, &q) else {
        bail!("no open focus item matches '{query}'");
    };

    // Rebuild the line, carrying the ORIGINAL origin date so the age survives the move.
    let today = Local::now().date_naive();
    let origin = md::find_since(&line).unwrap_or(today);
    let (text, prio) = task_text(&line);
    let new_text = if untag {
        retag(&text, None)
    } else if tag.is_some() {
        retag(&text, tag)
    } else {
        text
    };
    if new_text.is_empty() {
        bail!("refusing to move a task with no text left");
    }
    let core = match &prio {
        Some(pr) => format!("- [ ] {new_text} {pr}"),
        None => format!("- [ ] {new_text}"),
    };
    let new_line = md::stamp_line(&core, today, origin);

    let dest_name = to.map(str::trim).filter(|d| !d.is_empty());
    match dest_name {
        // cross-profile: write the destination FIRST, then commit the source removal,
        // so a failed destination write can never drop the task.
        Some(d) if d != p.name => {
            let dp = config::resolve(Some(d))?;
            let dnote = daily::today_path(&dp);
            if !dnote.exists() {
                daily::run(&dp, log)?; // bootstrap the destination's note
            }
            let dcontent = fs::read_to_string(&dnote)?;
            let dnew = md::insert_under_heading(&dcontent, "Focus", &[new_line.clone()]);
            fs::write(&dnote, dnew)?;
            fs::write(&src_note, src_without)?;
            log.info("focus", &format!("moved to {d}: {}", new_line.trim()));
            println!("moved to {d} {}", new_line.trim());
        }
        // same profile: a re-tag in place
        _ => {
            let updated = md::insert_under_heading(&src_without, "Focus", &[new_line.clone()]);
            fs::write(&src_note, updated)?;
            log.info("focus", &format!("retagged in {}", src_note.display()));
            println!("{}", new_line.trim());
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "\
## Focus
- [ ] pmp: ship the thing (3d) <!-- since:2026-07-18 --> #high
- [ ] plain task (1d) <!-- since:2026-07-20 -->

## Notes
after
";

    #[test]
    fn task_text_strips_stamp_checkbox_and_priority_keeping_case() {
        let (t, p) = task_text("- [ ] PMP: Ship the Thing (3d) <!-- since:2026-07-18 --> #high");
        assert_eq!(t, "PMP: Ship the Thing"); // case preserved
        assert_eq!(p.as_deref(), Some("#high"));

        let (t, p) = task_text("    - [/] in progress item (2d) <!-- since:2026-07-19 -->");
        assert_eq!(t, "in progress item");
        assert_eq!(p, None);
    }

    #[test]
    fn task_text_strips_a_doubled_checkbox() {
        // hand-edited notes sometimes carry `- [ ] - [ ] text`; the inner box must not
        // survive into the moved text or it renders as a nested checkbox.
        let (t, _) = task_text("- [ ] - [ ] reset julies account (2d) <!-- since:2026-07-19 -->");
        assert_eq!(t, "reset julies account");
    }

    #[test]
    fn retag_adds_swaps_and_removes_the_prefix() {
        assert_eq!(retag("ship it", Some("binks")), "binks: ship it");
        assert_eq!(retag("pmp: ship it", Some("binks")), "binks: ship it");
        assert_eq!(retag("pmp: ship it", None), "ship it");
        assert_eq!(retag("ship it", None), "ship it");
    }

    #[test]
    fn retag_cleans_a_checkbox_hiding_behind_the_tag() {
        // `- [ ] proj: - [ ] text` — the inner box sits AFTER the tag, so stripping
        // checkboxes off the raw line alone isn't enough.
        assert_eq!(
            retag("myproj: - [ ] fix the thing", Some("myproj")),
            "myproj: fix the thing"
        );
        assert_eq!(retag("myproj: - [ ] fix the thing", None), "fix the thing");
    }

    #[test]
    fn retag_leaves_sentence_colons_and_urls_alone() {
        // the head has spaces -> not a tag
        let s = "screen 2 orange: remove version";
        assert_eq!(retag(s, None), s);
        // a URL scheme is not a tag
        let u = "https://example.com/x";
        assert_eq!(retag(u, None), u);
        // ...and tagging one prefixes rather than mangles it
        assert_eq!(retag(u, Some("binks")), "binks: https://example.com/x");
    }

    #[test]
    fn take_first_pulls_the_matching_open_line_only() {
        let (rest, line) = take_first(NOTE, "ship the thing").unwrap();
        assert!(line.contains("pmp: ship the thing"));
        assert!(!rest.contains("ship the thing"));
        assert!(rest.contains("plain task")); // sibling untouched
        assert!(rest.ends_with("after\n"));
    }

    #[test]
    fn take_first_ignores_mirrored_rollup_tasks() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n- [ ] mirrored theirs\n\n## Notes\n",
            md::ROLLUP_START
        );
        assert!(take_first(&note, "mirrored").is_none());
        assert!(take_first(&note, "mine").is_some());
    }

    #[test]
    fn moved_line_keeps_its_original_age() {
        let (_rest, line) = take_first(NOTE, "ship the thing").unwrap();
        let origin = md::find_since(&line).unwrap();
        let (text, prio) = task_text(&line);
        let core = format!("- [ ] {} {}", retag(&text, None), prio.unwrap());
        // re-stamped from the ORIGINAL origin, so the since-date survives the move
        let out = md::stamp_line(&core, chrono::NaiveDate::from_ymd_opt(2026, 7, 21).unwrap(), origin);
        assert!(out.contains("<!-- since:2026-07-18 -->"));
        assert!(out.contains("(3d)"));
        assert!(out.contains("#high"));
        assert!(!out.contains("pmp:")); // untagged
    }
}
