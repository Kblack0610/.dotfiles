//! `notes today` — idempotent daily-note creation with carry-forward.
//!
//! Model: a *backlog → on-deck → in-progress* pipeline with time-relative wording.
//!   - **Focus** = "now / in progress": unfinished items carry forward, day-stamped.
//!   - **Due** = "on deck / coming up" (formerly Priority): dated tasks surface here
//!     within `LEAD_DAYS` of their date and carry forward until done or pushed later.
//!   - A single inline `[YYYY-MM-DD]` tag is the only verb — it both defers a task
//!     (a far-future date pushes it out to the `scheduled` backlog) and, once the
//!     date nears, resurfaces it in Due. Tagging a surfaced task again pushes it back.
//!   - **scheduled** (formerly carryover) is the holding pen for future-dated tasks;
//!     **Fun** is a standing backlog. Both are linked at the bottom of the note.

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
        // `carryover` kept as a back-compat alias — the file moved to scheduled.md.
        "scheduled" | "carryover" | "carry" => p.scheduled.clone(),
        "zettel" => p.zettel.clone(),
        "meetings" => p.meetings.clone(),
        "index" => p.index.clone(),
        "inbox" => p.inbox.clone(),
        "inbox-today" => p.inbox.join(format!("{}.md", Local::now().date_naive().format("%Y-%m-%d"))),
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

    let mut projects = String::new();
    let mut focus_keep: Vec<String> = Vec::new();
    let mut focus_defer: Vec<String> = Vec::new();
    let mut due_keep: Vec<String> = Vec::new();
    let mut due_defer: Vec<String> = Vec::new();

    if let Some(prev) = latest_prev(&p.daily, &today_s)? {
        let prev_date = file_date(&prev).unwrap_or(today);
        let content = fs::read_to_string(&prev)
            .with_context(|| format!("reading previous note {}", prev.display()))?;

        if let Some(lines) = md::section_lines(&content, "Current Projects") {
            projects = lines.join("\n");
        }

        // Focus = "now": carry unfinished items forward; a task dated beyond the lead
        // window is pushed out to the scheduled backlog instead of cluttering today.
        if let Some(lines) = md::section_lines(&content, "Focus") {
            let carried: Vec<String> = lines
                .iter()
                .filter(|l| md::is_task(l) && !md::is_checked(l) && !md::is_empty_unchecked(l))
                .map(|l| md::stamp_line(l, today, prev_date))
                .collect();
            (focus_keep, focus_defer) = route_by_due(&carried, today);
        }

        // Due = "on deck" (formerly Priority): carry forward, pushing far-future items
        // out to scheduled. Fall back to a legacy `## Priority` section for migration.
        let due_src = md::section_lines(&content, "Due")
            .or_else(|| md::section_lines(&content, "Priority"));
        if let Some(lines) = due_src {
            let carried = carry(&lines, today, prev_date);
            (due_keep, due_defer) = route_by_due(&carried, today);
        }
    }

    // Current Projects precedence:
    //   1. the hand-curated `## Current` lane of the project index (source of truth —
    //      re-derived each day so editing the index changes tomorrow's note), else
    //   2. carry-forward from the previous note (above), else
    //   3. auto-discovery from the `projects` dir.
    if let Some(lane) = current_lane_from_index(p) {
        projects = lane;
    }
    if projects.trim().is_empty() {
        projects = discover_projects(p);
    }

    // Scheduled backlog: surface any task now within the lead window into today's Due,
    // then push the newly-deferred Focus/Due items back into the pen.
    let sched_before = fs::read_to_string(&p.scheduled).unwrap_or_default();
    let (promoted, sched_pruned) = promote_scheduled(&sched_before, today);
    let n_promoted = promoted.len();

    let mut due_lines = due_keep;
    let mut due_keys: std::collections::HashSet<String> =
        due_lines.iter().map(|l| md::task_key(l)).collect();
    for pr in promoted {
        if due_keys.insert(md::task_key(&pr)) {
            due_lines.push(pr);
        }
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
    s.push_str("\n## Focus\n");
    for l in &focus_keep {
        s.push_str(l);
        s.push('\n');
    }
    s.push_str("- [ ] \n\n");
    s.push_str("## Notes\n\n");
    s.push_str("## Due\n");
    for l in &due_lines {
        s.push_str(l);
        s.push('\n');
    }
    s.push('\n');

    fs::write(note, s).with_context(|| format!("writing {}", note.display()))?;
    if n_promoted > 0 {
        log.info("today", &format!("surfaced {n_promoted} scheduled item(s) into Due"));
    }

    // Persist the scheduled backlog: pruned (promoted removed) + newly deferred items.
    let defers: Vec<String> = focus_defer.into_iter().chain(due_defer).collect();
    let mut seen: std::collections::HashSet<String> = sched_pruned
        .lines()
        .filter(|l| md::is_task(l))
        .map(md::task_key)
        .collect();
    let fresh: Vec<String> = defers
        .into_iter()
        .filter(|l| seen.insert(md::task_key(l)))
        .collect();
    let n_deferred = fresh.len();
    let sched_after = if fresh.is_empty() {
        sched_pruned
    } else {
        md::insert_under_heading(&sched_pruned, "Active", &fresh)
    };
    if sched_after != sched_before {
        fs::write(&p.scheduled, &sched_after)
            .with_context(|| format!("writing {}", p.scheduled.display()))?;
        if n_deferred > 0 {
            log.info("today", &format!("deferred {n_deferred} item(s) to scheduled backlog"));
        }
    }
    Ok(())
}

/// Read the `## Current` lane of the hand-curated project index (`lab/projects/index.md`),
/// which is the source of truth for what's active. Returns the lane's lines verbatim
/// (blank + placeholder `-`/`_…_` lines dropped) so the user's wikilinks flow straight
/// into the daily note. `None` when the index is unset, absent, or has no `## Current`
/// entries — callers then fall back to carry-forward / discovery.
fn current_lane_from_index(p: &Profile) -> Option<String> {
    let idx = p.project_index.as_ref()?;
    let content = fs::read_to_string(idx).ok()?;
    let lines = md::section_lines(&content, "Current")?;
    let kept: Vec<String> = lines
        .into_iter()
        .filter(|l| {
            let t = l.trim();
            !t.is_empty() && t != "-" && !(t.starts_with('_') && t.ends_with('_'))
        })
        .collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept.join("\n"))
    }
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

/// How many days ahead of its `[date]` a task surfaces in Due ("a couple days
/// before"). While `due > today + LEAD_DAYS` the task waits in the scheduled backlog.
const LEAD_DAYS: i64 = 2;

/// Drop checked + empty items; day-stamp the rest. Non-task lines pass through.
fn carry(lines: &[String], today: NaiveDate, prev_date: NaiveDate) -> Vec<String> {
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
        .collect()
}

/// Partition carried lines into `(keep, defer)`: a task dated more than `LEAD_DAYS`
/// ahead is deferred to the scheduled backlog; undated, due-soon, and overdue stay.
fn route_by_due(lines: &[String], today: NaiveDate) -> (Vec<String>, Vec<String>) {
    let horizon = today + chrono::Duration::days(LEAD_DAYS);
    let mut keep = Vec::new();
    let mut defer = Vec::new();
    for l in lines {
        match md::find_due(l) {
            Some(due) if due > horizon => defer.push(l.clone()),
            _ => keep.push(l.clone()),
        }
    }
    (keep, defer)
}

/// Pull tasks whose due-date is within the lead window (or overdue) out of the
/// scheduled backlog's `## Active`. Surfaced lines have their `[date]` token stripped
/// and a fresh day-count stamped. Returns `(surfaced, remaining_scheduled_content)`.
fn promote_scheduled(content: &str, today: NaiveDate) -> (Vec<String>, String) {
    let horizon = today + chrono::Duration::days(LEAD_DAYS);
    let mut promoted = Vec::new();
    let mut out: Vec<String> = Vec::new();
    let mut in_active = false;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            in_active = rest.trim().eq_ignore_ascii_case("Active");
            out.push(line.to_string());
            continue;
        }
        if in_active && md::is_task(line) && !md::is_checked(line) {
            if let Some(due) = md::find_due(line) {
                if due <= horizon {
                    promoted.push(md::stamp_line(&md::strip_due(line), today, today));
                    continue; // drop from the scheduled backlog
                }
            }
        }
        out.push(line.to_string());
    }
    let mut new_content = out.join("\n");
    if content.ends_with('\n') && !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    (promoted, new_content)
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
    let sched = config::wikilink(&p.root, &p.scheduled);
    if !content.ends_with('\n') {
        content.push('\n');
    }
    let projects_link = p
        .project_index
        .as_ref()
        .map(|pi| format!(" · Projects: [[{}]]", config::wikilink(&p.root, pi)))
        .unwrap_or_default();
    content.push_str(&format!("\n---\nBacklogs: [[{fun}]] · [[{sched}]]{projects_link}\n"));
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
    // One-time migration: the carryover backlog became the scheduled holding pen.
    // Rename it in place so existing items are preserved (only when scheduled is absent).
    if !p.scheduled.exists() && p.carryover.exists() {
        if let Some(parent) = p.scheduled.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(&p.carryover, &p.scheduled)
            .with_context(|| format!("migrating {} → {}", p.carryover.display(), p.scheduled.display()))?;
        // Relabel the default header/tag/description so the migrated file reads as
        // Scheduled. Exact-match replacements — a no-op if the user customized them.
        if let Ok(c) = fs::read_to_string(&p.scheduled) {
            let relabeled = c
                .replace("tags: [backlog, carryover]", "tags: [backlog, scheduled]")
                .replace("# Carry Over\n", "# Scheduled\n")
                .replace(
                    "Triage queue: unfinished items roll here from daily Focus.",
                    "Holding pen for future-dated tasks — they surface in a daily note's Due section near their date.",
                );
            if relabeled != c {
                fs::write(&p.scheduled, relabeled)?;
            }
        }
        log.info(
            "backlog",
            &format!("migrated carryover → {}", p.scheduled.display()),
        );
    }
    ensure_backlog_file(
        &p.scheduled,
        "Scheduled",
        "scheduled",
        "Holding pen for future-dated tasks — they surface in a daily note's Due section near their date.",
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
            scheduled: r.join("journal/backlogs/scheduled.md"),
            summaries: r.join("journal/summaries"),
            continuous: r.join("journal/summaries/continuous"),
            monthly: r.join("journal/summaries/monthly"),
            archive: r.join("journal/daily_archive"),
            zettel: r.join("journal/permanent"),
            meetings: r.join("journal/meetings"),
            index: r.join("journal/index"),
            projects: None,
            project_index: None,
            inbox: r.join("inbox"),
            tag_scan: Vec::new(),
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

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn v(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn route_by_due_defers_far_future_only() {
        // today 2026-06-30, LEAD_DAYS=2 → horizon 2026-07-02
        let lines = v(&[
            "- [ ] far [2026-07-15]",
            "- [ ] soon [2026-07-01]",
            "- [ ] overdue [2026-06-01]",
            "- [ ] undated",
        ]);
        let (keep, defer) = route_by_due(&lines, d("2026-06-30"));
        assert_eq!(defer, v(&["- [ ] far [2026-07-15]"]));
        assert_eq!(
            keep,
            v(&["- [ ] soon [2026-07-01]", "- [ ] overdue [2026-06-01]", "- [ ] undated"])
        );
    }

    #[test]
    fn route_by_due_horizon_is_inclusive() {
        // a task due exactly on the horizon stays (surfaces), not deferred
        let (keep, defer) = route_by_due(&v(&["- [ ] edge [2026-07-02]"]), d("2026-06-30"));
        assert!(defer.is_empty());
        assert_eq!(keep, v(&["- [ ] edge [2026-07-02]"]));
    }

    #[test]
    fn promote_scheduled_surfaces_due_and_overdue() {
        let content = "\
# Scheduled

## Active
- [ ] far [2026-07-15]
- [ ] soon [2026-07-01]
- [ ] overdue [2026-06-20]
- [ ] undated task

## Done
- [x] finished [2026-01-01]
";
        let (promoted, remaining) = promote_scheduled(content, d("2026-06-30"));
        // soon + overdue surface; far + undated stay; Done is never touched
        assert_eq!(promoted.len(), 2);
        // surfaced lines have the [date] token stripped and a since: stamp added
        assert!(promoted.iter().any(|l| l.contains("soon") && !l.contains("2026-07-01") && l.contains("since:2026-06-30")));
        assert!(promoted.iter().any(|l| l.contains("overdue") && !l.contains("2026-06-20") && l.contains("since:2026-06-30")));
        // the pen keeps the far-future + undated items and the whole Done section
        assert!(remaining.contains("- [ ] far [2026-07-15]"));
        assert!(remaining.contains("- [ ] undated task"));
        assert!(remaining.contains("- [x] finished [2026-01-01]"));
        // and no longer lists the surfaced ones in Active
        let active = &remaining[..remaining.find("## Done").unwrap()];
        assert!(!active.contains("soon"));
        assert!(!active.contains("overdue"));
    }

    #[test]
    fn current_lane_reads_index_and_falls_back() {
        let dir = std::env::temp_dir().join(format!("notes-idx-{}", std::process::id()));
        let projects = dir.join("lab/projects/current");
        std::fs::create_dir_all(&projects).unwrap();
        let mut p = profile(dir.to_str().unwrap());
        p.projects = Some(projects.clone());
        p.project_index = Some(projects.parent().unwrap().join("index.md"));

        // no index file yet → None
        assert!(current_lane_from_index(&p).is_none());

        // index with a Current lane (plus a placeholder to ignore) → verbatim lines
        std::fs::write(
            p.project_index.as_ref().unwrap(),
            "# Projects\n\n## Current\n- [[current/placemyparents/summary|placemyparents]]\n- [[current/time-tangle/summary|time-tangle]]\n\n## Backlog\n- _(nothing)_\n",
        )
        .unwrap();
        let lane = current_lane_from_index(&p).unwrap();
        assert!(lane.contains("placemyparents"));
        assert!(lane.contains("time-tangle"));
        assert!(!lane.contains("nothing"));

        // an empty Current lane → None (so caller falls back)
        std::fs::write(p.project_index.as_ref().unwrap(), "## Current\n- \n\n## Backlog\n- x\n").unwrap();
        assert!(current_lane_from_index(&p).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn promote_scheduled_noop_when_all_far() {
        let content = "## Active\n- [ ] later [2027-01-01]\n\n## Done\n";
        let (promoted, remaining) = promote_scheduled(content, d("2026-06-30"));
        assert!(promoted.is_empty());
        assert_eq!(remaining, content);
    }
}
