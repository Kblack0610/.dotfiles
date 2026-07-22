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
use crate::inbox;
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
        "recurring" => p.recurring.clone(),
        "zettel" => p.zettel.clone(),
        "meetings" => p.meetings.clone(),
        "index" => p.index.clone(),
        "inbox" => p.inbox.clone(),
        "inbox-today" => p.inbox.join(format!(
            "{}.md",
            Local::now().date_naive().format("%Y-%m-%d")
        )),
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
    // Renders the `## Work` roster (job link + open-count), like refresh_watches renders
    // `## Watches`. Running every `notes today` keeps the counts current as job notes sync in.
    refresh_work(p, log, &note)?;
    refresh_watches(p, log, &note)?;
    // Renders the `## Comms` section from the triage poller's per-profile surface file,
    // like `refresh_watches` renders `## Watches`. No-op when comms is unconfigured.
    crate::comms::refresh(p, log, &note)?;
    refresh_inbox(p, log, &note)?;
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
        let mut content = fs::read_to_string(&prev)
            .with_context(|| format!("reading previous note {}", prev.display()))?;
        // Drop the trailing backlog footer before extracting sections. The last H2
        // (`## Due`, or legacy `## Priority`) sits directly above `\n---\nBacklogs:`,
        // and `capture` only stops at the next H2 — so without this the footer bleeds
        // into the carried section and re-seeds a stale `Backlogs:` line downstream.
        strip_backlog_footer(&mut content);

        if let Some(lines) = md::section_lines(&content, "Current Projects") {
            projects = lines.join("\n");
        }

        // Focus = "now": carry unfinished items forward; a task dated beyond the lead
        // window is pushed out to the scheduled backlog instead of cluttering today.
        if let Some(lines) = md::section_lines(&content, "Focus") {
            let carried: Vec<String> = lines
                .iter()
                .filter(|l| md::is_open_task(l))
                .map(|l| md::stamp_line(l, today, prev_date))
                .collect();
            (focus_keep, focus_defer) = route_by_due(&carried, today);
        }

        // Due = "on deck" (formerly Priority): carry forward, pushing far-future items
        // out to scheduled. Fall back to a legacy `## Priority` section for migration.
        let due_src =
            md::section_lines(&content, "Due").or_else(|| md::section_lines(&content, "Priority"));
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

    // Recurring backlog: emit a fresh copy of each habit whose `(every:…)` cadence
    // fires today into Due. The master file is read-only here (unlike scheduled, which
    // prunes) so the habit returns every cycle. Deduped against carried/promoted items.
    let recurring_before = fs::read_to_string(&p.recurring).unwrap_or_default();
    let mut n_recurring = 0;
    for rec in emit_recurring(&recurring_before, today) {
        if due_keys.insert(md::task_key(&rec)) {
            due_lines.push(rec);
            n_recurring += 1;
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

    md::write_atomic(note, &s).with_context(|| format!("writing {}", note.display()))?;
    if n_promoted > 0 {
        log.info(
            "today",
            &format!("surfaced {n_promoted} scheduled item(s) into Due"),
        );
    }
    if n_recurring > 0 {
        log.info(
            "today",
            &format!("emitted {n_recurring} recurring item(s) into Due"),
        );
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
        md::write_atomic(&p.scheduled, &sched_after)
            .with_context(|| format!("writing {}", p.scheduled.display()))?;
        if n_deferred > 0 {
            log.info(
                "today",
                &format!("deferred {n_deferred} item(s) to scheduled backlog"),
            );
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

/// Active-project `(name, summary_path)` pairs from the configured `projects` dir
/// (e.g. lab/projects/current): each immediate subdir that contains a `summary.md`,
/// sorted by name, `_`-prefixed dirs (e.g. `_index`) skipped. Empty when no `projects`
/// dir is configured or it has no qualifying entries. Shared source of truth between
/// the daily note's discovery fallback and the `notes projects` picker.
pub(crate) fn discover_project_dirs(p: &Profile) -> Vec<(String, PathBuf)> {
    let Some(dir) = p.projects.as_ref() else {
        return Vec::new();
    };
    if !dir.is_dir() {
        return Vec::new();
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
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
}

/// Discover active projects from the configured `projects` dir as daily-note wikilinks:
/// one `- [[…|name]]` per `discover_project_dirs` entry. Returns "" when there are none.
fn discover_projects(p: &Profile) -> String {
    discover_project_dirs(p)
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

/// Emit today's due recurring habits from the recurring backlog's `## Active`: for each
/// unchecked task whose `(every:…)` cadence fires on `today`, produce a fresh daily copy
/// with the cadence token stripped and a `(0d) <!-- since:today -->` stamp. Read-only —
/// the backlog file is never modified (the master line recurs every cycle).
fn emit_recurring(content: &str, today: NaiveDate) -> Vec<String> {
    let mut out = Vec::new();
    let mut in_active = false;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            in_active = rest.trim().eq_ignore_ascii_case("Active");
            continue;
        }
        if in_active && md::is_task(line) && !md::is_checked(line) && md::recurs_on(line, today) {
            out.push(md::stamp_line(&md::strip_every(line), today, today));
        }
    }
    out
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
    md::write_atomic(&note, &content)?;
    log.info("link-refs", &format!("linked {} ref(s)", links.len()));
    Ok(())
}

/// Add the backlog footer if not already present.
fn ensure_footer(p: &Profile, note: &Path) -> Result<()> {
    let mut content = fs::read_to_string(note)?;
    if content.contains("Backlogs:") {
        return Ok(());
    }
    // The linked backlogs are config-driven (`footer_backlogs`), so the list is edited
    // in config.toml, not hardcoded here. Defaults to fun + scheduled.
    let backlogs = p
        .footer_backlogs
        .iter()
        .map(|b| format!("[[{}]]", config::wikilink(&p.root, b)))
        .collect::<Vec<_>>()
        .join(" · ");
    if !content.ends_with('\n') {
        content.push('\n');
    }
    let projects_link = p
        .project_index
        .as_ref()
        .map(|pi| format!(" · Projects: [[{}]]", config::wikilink(&p.root, pi)))
        .unwrap_or_default();
    // Surface the inbox as a link + pending count when there's anything to triage.
    let (pending, _stale) = inbox::backlog_counts(p);
    let inbox_link = if pending > 0 {
        format!(
            " · Inbox ({pending}): [[{}]]",
            config::wikilink(&p.root, &p.inbox)
        )
    } else {
        String::new()
    };
    content.push_str(&format!(
        "\n---\nBacklogs: {backlogs}{projects_link}{inbox_link}\n"
    ));
    md::write_atomic(note, &content)?;
    Ok(())
}

/// Truncate a note at its backlog footer (`\n---\nBacklogs: …`), leaving the body.
/// Carry-forward reads the previous note's sections, and the last H2 sits directly
/// above the footer with no H2 between — so stripping it here keeps the footer out
/// of the carried section (and thus out of tomorrow's note).
fn strip_backlog_footer(content: &mut String) {
    if let Some(idx) = content.find("\n---\nBacklogs:") {
        content.truncate(idx);
    }
}

pub(crate) fn insert_before_footer(content: &str, block: &str) -> String {
    if let Some(idx) = content.find("\n---\nBacklogs:") {
        let (head, tail) = content.split_at(idx);
        format!("{}{}{}", head.trim_end(), block, tail)
    } else {
        format!("{}{}", content.trim_end(), block)
    }
}

/// Remove a `## heading` section (its heading line + body up to the next `## ` heading,
/// the `---` footer rule, or EOF). Returns the content unchanged when the heading is
/// absent. Used to re-render the `## Watches` section in place each run.
pub(crate) fn remove_section(content: &str, heading: &str) -> String {
    let target = format!("## {heading}");
    let lines: Vec<&str> = content.lines().collect();
    let Some(start) = lines.iter().position(|l| l.trim() == target) else {
        return content.to_string();
    };
    let mut end = lines.len();
    for (i, l) in lines.iter().enumerate().skip(start + 1) {
        if l.trim_start().starts_with("## ") || l.trim() == "---" {
            end = i;
            break;
        }
    }
    let mut kept: Vec<&str> = Vec::new();
    kept.extend_from_slice(&lines[..start]);
    kept.extend_from_slice(&lines[end..]);
    let mut out = kept.join("\n");
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// Open tasks from a note's `## Focus` - unchecked, non-empty, real task lines only (the
/// job notes mix prose, pasted terminal output and `---` rules into Focus). Used to COUNT
/// a job's open work for the `## Work` roster; `md::section_lines` stops at
/// [`md::ROLLUP_START`], so a note carrying a legacy inline block is not double-counted.
fn job_focus_tasks(content: &str) -> Vec<String> {
    md::section_lines(content, "Focus")
        .unwrap_or_default()
        .into_iter()
        .filter(|l| md::is_open_task(l))
        .collect()
}

/// Remove the legacy inline-rollup remnants from `## Focus`: the `<!-- rollup:start -->`
/// sentinel line, and each `### <job>` mirror heading (its first token in `names`) together
/// with the consecutive task lines beneath it.
///
/// Surgical on purpose. An earlier design mirrored each job's tasks inline under Focus; the
/// roster now lives in its own `## Work` section, so old notes must be migrated. But a note
/// can have the user's OWN tasks interleaved with a stale block (people hand-edit inside
/// Focus, `---` rules and all), so a blunt "delete sentinel..end-of-Focus" would eat real
/// tasks. This drops ONLY a recognized `### <job>` heading and its own task lines; every
/// authored line is preserved. A no-op once no note carries these - byte-stable, idempotent.
fn strip_legacy_rollup(content: &str, names: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut in_focus = false;
    let mut dropping = false; // inside a recognized `### <job>` mirror sub-block
    for line in content.lines() {
        if line.trim_start().starts_with("## ") {
            in_focus = line.trim() == "## Focus";
            dropping = false;
            out.push(line.to_string());
            continue;
        }
        if in_focus {
            if line.trim() == md::ROLLUP_START {
                continue; // drop the sentinel wherever it sits
            }
            if let Some(rest) = line.trim_start().strip_prefix("### ") {
                let label = rest.split_whitespace().next().unwrap_or("");
                if names.iter().any(|n| n == label) {
                    dropping = true; // drop this heading and the task lines under it
                    continue;
                }
                dropping = false; // a `### ` the user wrote - keep it
            } else if dropping {
                if md::is_task(line) {
                    continue; // a mirror task line
                }
                dropping = false; // first non-task ends the mirror sub-block
            }
        }
        out.push(line.to_string());
    }
    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

/// Render the currently-registered Sentinel watches as daily-note lines, unhealthy
/// first. Scans `p.watches` for `*.yaml` (active) and `*.yaml.paused` (paused), reads
/// each manifest's name/description/probe/interval and the live `<name>.state` from
/// `p.watches_state`, and returns `- <STATE> <name> - <desc> (<probe>, <interval>)`
/// lines. Empty when `watches` is unset, the dir is absent, or it has no manifests.
/// Read-only — never writes. ASCII state markers (OK / TRIP / ERROR / paused / -).
fn discover_watches(p: &Profile) -> Vec<String> {
    let Some(dir) = p.watches.as_ref() else {
        return Vec::new();
    };
    if !dir.is_dir() {
        return Vec::new();
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut rows: Vec<(u8, String, String)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(fname) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let (stem, paused) = if let Some(s) = fname.strip_suffix(".yaml") {
            (s, false)
        } else if let Some(s) = fname.strip_suffix(".yaml.paused") {
            (s, true)
        } else {
            continue;
        };
        let content = fs::read_to_string(&path).unwrap_or_default();
        let name = md::parse_yaml_scalar(&content, "name").unwrap_or_else(|| stem.to_string());
        let desc = md::parse_yaml_scalar(&content, "description").unwrap_or_default();
        let probe = md::parse_yaml_scalar(&content, "probe").unwrap_or_else(|| "?".into());
        let interval = md::parse_yaml_scalar(&content, "interval").unwrap_or_else(|| "?".into());
        let state = if paused {
            "paused".to_string()
        } else {
            fs::read_to_string(p.watches_state.join(format!("{name}.state")))
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "-".to_string())
        };
        // Unhealthy first (0), healthy/unknown next (1), paused last (2); then by name.
        let rank = match state.as_str() {
            "TRIP" | "ERROR" => 0,
            "paused" => 2,
            _ => 1,
        };
        let line = if desc.is_empty() {
            format!("- {state} {name} ({probe}, {interval})")
        } else {
            format!("- {state} {name} - {desc} ({probe}, {interval})")
        };
        rows.push((rank, name, line));
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    rows.into_iter().map(|(_, _, l)| l).collect()
}

/// Refresh the daily note's `## Inbox` section with today's quick-captures (the bullet
/// lines in `inbox/<today>.md`). Runs every `notes today` so captures added during the
/// day appear at the bottom of the note. Self-hiding: no section when today's inbox file
/// is absent or has no bullets. Read-only against the inbox (only the daily note is
/// written).
fn refresh_inbox(p: &Profile, log: &Logger, note: &Path) -> Result<()> {
    let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
    let inbox_today = p.inbox.join(format!("{today}.md"));
    // Raw capture lines from today's inbox file (bullet lines only); the render loop
    // splits each into its core text + optional session marker.
    let bodies: Vec<String> = fs::read_to_string(&inbox_today)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.trim_start().starts_with("- "))
        .map(|l| l.to_string())
        .collect();

    let content = fs::read_to_string(note)?;
    // Preserve which captures the user already ticked off in the existing section, so a
    // re-run doesn't reset the checkmark (the section is rebuilt from the inbox file).
    // Keyed on the core text (session marker/suffix stripped) so source and rendered match.
    let checked: std::collections::HashSet<String> = md::section_lines(&content, "Inbox")
        .unwrap_or_default()
        .into_iter()
        .filter(|l| md::is_checked(l))
        .filter_map(|l| inbox_core(&l))
        .collect();

    let stripped = remove_section(&content, "Inbox");
    let new_content = if bodies.is_empty() {
        stripped
    } else {
        let mut block = String::from("\n\n## Inbox\n");
        for line in &bodies {
            let Some(core) = inbox_core(line) else {
                continue;
            };
            let mark = if checked.contains(&core) { "x" } else { " " };
            // Surface a short session id (`(sess 8e87fd5e)`) so the capture links back to
            // its conversation via `claude -r <id>`; only when the source carried a tag.
            let suffix = inbox_session(line)
                .map(|id| format!(" (sess {})", id.split('-').next().unwrap_or(&id)))
                .unwrap_or_default();
            block.push_str(&format!("- [{mark}] {core}{suffix}\n"));
        }
        insert_before_footer(&stripped, &block)
    };
    if new_content != content {
        md::write_atomic(note, &new_content)?;
        log.info(
            "today",
            &format!("refreshed {} inbox capture(s) in ## Inbox", bodies.len()),
        );
    }
    Ok(())
}

/// Core text of an inbox capture line, for display + dedup: strip a leading bullet or
/// checkbox (`-`, `- [ ]`, `- [x]`), a trailing `<!-- … -->` comment (the source's
/// session marker), and a trailing ` (sess …)` suffix (a re-rendered task). `None` when
/// nothing meaningful remains.
fn inbox_core(line: &str) -> Option<String> {
    let t = line.trim();
    let rest = t
        .strip_prefix("- [ ]")
        .or_else(|| t.strip_prefix("- [x]"))
        .or_else(|| t.strip_prefix("- [X]"))
        .or_else(|| t.strip_prefix('-'))?;
    let mut rest = rest.trim();
    if let Some(i) = rest.find("<!--") {
        rest = rest[..i].trim_end();
    }
    if rest.ends_with(')') {
        if let Some(p) = rest.rfind(" (sess ") {
            rest = rest[..p].trim_end();
        }
    }
    if rest.is_empty() {
        None
    } else {
        Some(rest.to_string())
    }
}

/// Extract the full session id from a `<!-- session:ID -->` marker on a line, if present.
fn inbox_session(line: &str) -> Option<String> {
    let marker = "<!-- session:";
    let i = line.find(marker)?;
    let after = &line[i + marker.len()..];
    let end = after.find("-->")?;
    let id = after[..end].trim();
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

/// Collect each rollup profile's open Focus tasks.
///
/// Infallible by construction, like `discover_watches`. `config::resolve` returns `Err`
/// for a name that is not defined, and `notes today` runs from the shell rc on every new
/// shell - so a single typo in `rollup` must not be able to take the command down. An
/// unresolvable entry is warned (Logger::warn always reaches stderr, so a genuine
/// misconfiguration still gets noticed) and skipped.
///
/// Resolve a rollup profile NAME to its latest source note: today's if it exists, else the
/// most recent prior one. Returns `(path, stale)` where `stale` is `Some(date)` when the note
/// is not today's. `None` when the name is this profile itself, does not resolve, or has no
/// notes yet. Used by `work_lines` to build the `## Work` roster line for each job.
fn rollup_source(p: &Profile, log: &Logger, name: &str) -> Option<(PathBuf, Option<String>)> {
    if name == p.name {
        return None; // a profile mirroring itself would duplicate its own Focus
    }
    let jp = match config::resolve(Some(name)) {
        Ok(jp) => jp,
        Err(e) => {
            log.warn("today", &format!("rollup: skipping '{name}': {e}"));
            return None;
        }
    };
    let today_s = Local::now().date_naive().format("%Y-%m-%d").to_string();
    let today_note = jp.daily.join(format!("{today_s}.md"));
    if today_note.exists() {
        Some((today_note, None))
    } else {
        match latest_prev(&jp.daily, &today_s) {
            Ok(Some(prev)) => {
                let d = file_date(&prev).map(|d| d.format("%Y-%m-%d").to_string());
                Some((prev, d))
            }
            // No note yet (a job whose log dir does not exist) contributes nothing.
            _ => None,
        }
    }
}

/// One collapsed roster line per rollup profile for the `## Work` section: a link to the
/// job's latest note plus its open-task count - a glance-value pointer, not the tasks
/// themselves (those live in the job note, reached with `gf` on the link). Every configured
/// job is listed even at zero open (a stable roster for now); a job with no note yet is
/// listed link-less. Infallible like `discover_watches`: a resolve/read failure degrades one
/// line, never aborts `notes today`.
fn work_lines(p: &Profile, log: &Logger) -> Vec<String> {
    let mut out = Vec::new();
    for name in &p.rollup {
        if name == &p.name {
            continue; // a profile listing itself is meaningless here
        }
        match rollup_source(p, log, name) {
            Some((src, _stale)) => {
                let content = fs::read_to_string(&src).unwrap_or_default();
                let n = job_focus_tasks(&content).len();
                let link = config::wikilink(&p.root, &src);
                out.push(format!("- {name} - [[{link}]] ({n} open)"));
            }
            // No note yet (e.g. a job whose log dir does not exist): still rostered, but
            // there is nothing to link to.
            None => out.push(format!("- {name} - (no note yet)")),
        }
    }
    out
}

/// Refresh the daily note's `## Work` section: one collapsed link + open-count per job in
/// `p.rollup`. Its own H2 section, kept above the footer like `## Watches`, regenerated every
/// run - so it is NOT carried forward into tomorrow's note and NOT folded into summaries.
///
/// No-op when `rollup` is empty. The notes config is machine-local and gitignored, so a
/// machine without the key must not add a section the next 5-minute sync would strip off the
/// machine that has it: that ping-pong is the same failure `refresh_watches` guards against.
///
/// Also strips any legacy inline rollup block from `## Focus` (the earlier design), so an
/// existing note upgrades in place - a no-op once the old block is gone.
fn refresh_work(p: &Profile, log: &Logger, note: &Path) -> Result<()> {
    if p.rollup.is_empty() {
        return Ok(());
    }
    let content = fs::read_to_string(note)?;
    let migrated = strip_legacy_rollup(&content, &p.rollup); // clean any legacy inline block
    let lines = work_lines(p, log);
    let stripped = remove_section(&migrated, "Work");
    let new_content = if lines.is_empty() {
        stripped
    } else {
        let mut block = String::from("\n\n## Work\n");
        for l in &lines {
            block.push_str(l);
            block.push('\n');
        }
        insert_before_footer(&stripped, &block)
    };
    if new_content != content {
        md::write_atomic(note, &new_content)?;
        log.info(
            "today",
            &format!("refreshed ## Work ({} job(s))", lines.len()),
        );
    }
    Ok(())
}

/// Refresh the daily note's `## Watches` section from the live Sentinel registry. Runs
/// every `notes today` (like `link_refs`) so state stays current. No-op when `watches`
/// is unset. Replaces any existing section in place, kept above the footer.
fn refresh_watches(p: &Profile, log: &Logger, note: &Path) -> Result<()> {
    if p.watches.is_none() {
        return Ok(());
    }
    let content = fs::read_to_string(note)?;
    let lines = discover_watches(p);
    let stripped = remove_section(&content, "Watches");
    let new_content = if lines.is_empty() {
        stripped
    } else {
        let mut block = String::from("\n\n## Watches\n");
        for l in &lines {
            block.push_str(l);
            block.push('\n');
        }
        insert_before_footer(&stripped, &block)
    };
    if new_content != content {
        md::write_atomic(note, &new_content)?;
        log.info(
            "today",
            &format!("refreshed {} watch(es) in ## Watches", lines.len()),
        );
    }
    Ok(())
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
        fs::rename(&p.carryover, &p.scheduled).with_context(|| {
            format!(
                "migrating {} → {}",
                p.carryover.display(),
                p.scheduled.display()
            )
        })?;
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
    ensure_backlog_file(
        &p.recurring,
        "Recurring",
        "recurring",
        "Standing habits: a task with an `(every:…)` token surfaces into a daily note's Due each matching day. Cadences: every:fri · every:mon,thu · every:weekday · every:day · every:1st · every:last.",
        log,
    )?;
    Ok(())
}

fn ensure_backlog_file(
    path: &Path,
    title: &str,
    tag: &str,
    desc: &str,
    log: &Logger,
) -> Result<()> {
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
            recurring: r.join("journal/backlogs/recurring.md"),
            footer_backlogs: vec![
                r.join("journal/backlogs/fun.md"),
                r.join("journal/backlogs/scheduled.md"),
            ],
            watches: None,
            watches_state: r.join("state/watch-companion"),
            rollup: Vec::new(),
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

    /// The real `## Focus` shape from a job-profile note (2026-07-15): a pasted
    /// terminal blob, plain prose bullets, a `----` rule, a malformed `- [ ]change` with
    /// no space, an indented child task, and a trailing empty `- [ ]`. Anything that
    /// mirrors this section has to survive all of it.
    const JOB_FOCUS: &str = "\
## Focus


❯ thansk, is  eveyrhgin up?... first wehn i hit rebot it sayis \"cant reboot\"
  first .. ... lastly.. when i rebooted intor runteim admin after restart

- for universal boot.
    - boot diff color(orange?)
    - player loop (reset)


----
- [ ] clarify boot layer is for networked use cases (2d) <!-- since:2026-07-13 -->
- [ ]change the endpoint autorun.zip, and call it /runtime (2d) <!-- since:2026-07-13 -->
- [x] already done thing (2d) <!-- since:2026-07-13 -->
- [ ] clickup ticket for investiagation of index.js renaming (2d) <!-- since:2026-07-13 -->
    - [ ] admin local ui (2d) <!-- since:2026-07-13 -->
- [ ]

## Notes
after
";

    #[test]
    fn job_focus_tasks_filters_prose_and_preserves_indent() {
        let tasks = job_focus_tasks(JOB_FOCUS);
        assert_eq!(
            tasks,
            vec![
                "- [ ] clarify boot layer is for networked use cases (2d) <!-- since:2026-07-13 -->",
                "- [ ]change the endpoint autorun.zip, and call it /runtime (2d) <!-- since:2026-07-13 -->",
                "- [ ] clickup ticket for investiagation of index.js renaming (2d) <!-- since:2026-07-13 -->",
                "    - [ ] admin local ui (2d) <!-- since:2026-07-13 -->",
            ]
        );
        // The child task keeps its indentation, which is the only thing tying it to its
        // parent once the mirror drops everything that is not a task.
        assert!(tasks[3].starts_with("    - [ ]"));
        // Prose, pasted output, rules and the empty placeholder are all gone.
        assert!(!tasks.iter().any(|t| t.contains("universal boot")));
        assert!(!tasks.iter().any(|t| t.contains("eveyrhgin")));
        assert!(!tasks.iter().any(|t| t.contains("----")));
        assert!(!tasks.iter().any(|t| md::is_checked(t)));
        assert!(!tasks.iter().any(|t| md::is_empty_unchecked(t)));
    }

    /// A job note that already carries its own rollup block must not re-mirror it.
    #[test]
    fn job_focus_tasks_ignores_a_nested_rollup_block() {
        let note = format!(
            "## Focus\n- [ ] mine\n\n{}\n\n### other\n- [ ] someone elses\n\n## Notes\n",
            md::ROLLUP_START
        );
        assert_eq!(job_focus_tasks(&note), vec!["- [ ] mine"]);
    }

    #[test]
    fn strip_legacy_rollup_removes_mirror_but_keeps_interleaved_tasks() {
        // A TANGLED note from the old inline design: the user hand-added their own tasks (and a
        // `---`) BELOW the sentinel, then the `### g` mirror block follows. The migration must
        // drop the sentinel + the mirror heading/tasks, and preserve every authored line -
        // deleting the user's interleaved tasks would be data loss.
        let note = format!(
            "## Focus\n- [ ] before\n\n{}\n- [ ] sync notes\n\n---\n\n- [x] done thing\n\n### g (2026-07-15) [[x]]\n- [ ] mirror one\n- [ ] mirror two\n\n## Notes\nkeep\n",
            md::ROLLUP_START
        );
        let out = strip_legacy_rollup(&note, &["g".to_string()]);
        // Mirror gone.
        assert!(!out.contains(md::ROLLUP_START));
        assert!(!out.contains("### g"));
        assert!(!out.contains("mirror one"));
        assert!(!out.contains("mirror two"));
        // Every authored line preserved - including the ones the user put below the sentinel.
        assert!(out.contains("- [ ] before"));
        assert!(out.contains("- [ ] sync notes"));
        assert!(out.contains("- [x] done thing"));
        assert!(out.contains("---"));
        assert!(out.contains("## Notes\nkeep"));
        // Idempotent, and a no-op on a note that never had a block.
        assert_eq!(out, strip_legacy_rollup(&out, &["g".to_string()]));
        let clean = "## Focus\n- [ ] a\n\n## Notes\nx\n";
        assert_eq!(strip_legacy_rollup(clean, &["g".to_string()]), clean);
        // A `### heading` the user wrote themselves (not a rollup name) is left alone.
        let user_h3 = "## Focus\n### my own subheading\n- [ ] a\n\n## Notes\n";
        assert_eq!(strip_legacy_rollup(user_h3, &["g".to_string()]), user_h3);
    }

    #[test]
    fn refresh_work_renders_roster_migrates_and_is_stable() {
        // Temp vault: a "g" job note with 2 open + 1 done Focus task (count = 2), an "e" job
        // with no note at all (rostered link-less), and a personal note that still carries a
        // legacy inline rollup block in Focus (must be migrated out).
        let dir = std::env::temp_dir().join(format!("notes-work-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("employment/jobs/g/log")).unwrap();
        fs::create_dir_all(dir.join("employment/jobs/e")).unwrap(); // exists, but no log/ dir
        fs::create_dir_all(dir.join("journal/daily")).unwrap();

        let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
        fs::write(
            dir.join(format!("employment/jobs/g/log/{today}.md")),
            "## Focus\n- [ ] open one\n- [ ] open two\n- [x] already done\n\n## Notes\n",
        )
        .unwrap();

        let pnote = dir.join("journal/daily").join(format!("{today}.md"));
        let pcontent = format!(
            "## Focus\n- [ ] mine\n\n{}\n\n### g [[employment/jobs/g/log/{today}]]\n- [ ] open one\n\n## Notes\n\n---\nBacklogs: [[backlogs/fun]]\n",
            md::ROLLUP_START
        );
        fs::write(&pnote, &pcontent).unwrap();

        let mut prof = profile(dir.to_str().unwrap());
        prof.name = "personal".into();
        prof.rollup = vec!["g".into(), "e".into()];
        let cfg = dir.join("config.toml");
        fs::write(
            &cfg,
            format!(
                "default_profile=\"personal\"\n\n[profile.personal]\nroot=\"{d}\"\ndaily=\"journal/daily\"\nrefs=\"journal/refs\"\nfun=\"journal/backlogs/fun.md\"\ncarryover=\"journal/backlogs/carryover.md\"\nsummaries=\"journal/summaries\"\narchive=\"journal/daily_archive\"\nzettel=\"journal/permanent\"\nindex=\"journal/index\"\n\n[profile.g]\nroot=\"{d}/employment/jobs/g\"\ndaily=\"log\"\nrefs=\"refs\"\nfun=\"b/f.md\"\ncarryover=\"b/c.md\"\nsummaries=\"s\"\narchive=\"a\"\nzettel=\"z\"\nindex=\"i\"\n\n[profile.e]\nroot=\"{d}/employment/jobs/e\"\ndaily=\"log\"\nrefs=\"refs\"\nfun=\"b/f.md\"\ncarryover=\"b/c.md\"\nsummaries=\"s\"\narchive=\"a\"\nzettel=\"z\"\nindex=\"i\"\n",
                d = dir.display()
            ),
        )
        .unwrap();
        std::env::set_var("NOTES_CONFIG", &cfg);

        let log = Logger::new(dir.join("log"), false);
        refresh_work(&prof, &log, &pnote).unwrap();
        let out = fs::read_to_string(&pnote).unwrap();

        // The `## Work` roster: g with a link + count, e listed link-less.
        assert!(out.contains("## Work"), "no Work section: {out}");
        assert!(
            out.contains(&format!("- g - [[employment/jobs/g/log/{today}]] (2 open)")),
            "{out}"
        );
        assert!(out.contains("- e - (no note yet)"), "{out}");
        // The legacy inline block is gone from Focus; the personal task and footer survive.
        assert!(
            !out.contains(md::ROLLUP_START),
            "legacy block not migrated: {out}"
        );
        assert!(!out.contains("### g "), "legacy heading left behind: {out}");
        assert!(out.contains("- [ ] mine"));
        assert!(out.contains("Backlogs: [[backlogs/fun]]"));

        // Byte-stable on a second run (no churn given shell-startup + 5-min sync).
        refresh_work(&prof, &log, &pnote).unwrap();
        assert_eq!(
            fs::read_to_string(&pnote).unwrap(),
            out,
            "Work section churned"
        );

        std::env::remove_var("NOTES_CONFIG");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn strip_backlog_footer_removes_footer_and_keeps_body() {
        // A note whose last H2 (`## Due`) sits directly above the footer: capture()
        // would grab the `---`/`Backlogs:` lines into Due, so they must be stripped
        // before carry-forward. The section then carries clean, and no stale
        // `Backlogs:` line pre-seeds tomorrow's note.
        let mut c = String::from(
            "# 2026-07-08\n\n## Due\n- [ ] ship it\n\n---\nBacklogs: [[backlogs/fun]] · [[backlogs/carryover]]\n",
        );
        strip_backlog_footer(&mut c);
        assert!(c.ends_with("- [ ] ship it\n"), "body preserved, got: {c:?}");
        assert!(!c.contains("Backlogs:"), "footer stripped");
        // The carried Due section no longer contains the footer lines.
        let due = md::section_lines(&c, "Due").unwrap();
        assert_eq!(due, vec!["- [ ] ship it".to_string()]);
    }

    #[test]
    fn strip_backlog_footer_noop_without_footer() {
        let mut c = String::from("# 2026-07-08\n\n## Due\n- [ ] ship it\n");
        let before = c.clone();
        strip_backlog_footer(&mut c);
        assert_eq!(c, before);
    }

    #[test]
    fn resolve_known_targets() {
        let p = profile("/vault");
        assert_eq!(
            resolve_path(&p, "daily-dir").unwrap(),
            PathBuf::from("/vault/journal/daily")
        );
        assert_eq!(
            resolve_path(&p, "refs").unwrap(),
            PathBuf::from("/vault/journal/refs")
        );
        assert_eq!(resolve_path(&p, "root").unwrap(), PathBuf::from("/vault"));
        assert_eq!(
            resolve_path(&p, "fun").unwrap(),
            PathBuf::from("/vault/journal/backlogs/fun.md")
        );
        // refs-today is under refs; daily note is under daily-dir
        assert!(resolve_path(&p, "refs-today")
            .unwrap()
            .starts_with("/vault/journal/refs"));
        assert!(resolve_path(&p, "daily")
            .unwrap()
            .starts_with("/vault/journal/daily"));
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
            v(&[
                "- [ ] soon [2026-07-01]",
                "- [ ] overdue [2026-06-01]",
                "- [ ] undated"
            ])
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
        assert!(promoted.iter().any(|l| l.contains("soon")
            && !l.contains("2026-07-01")
            && l.contains("since:2026-06-30")));
        assert!(promoted.iter().any(|l| l.contains("overdue")
            && !l.contains("2026-06-20")
            && l.contains("since:2026-06-30")));
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
            "# Projects\n\n## Current\n- [[current/myapp/summary|myapp]]\n- [[current/time-tangle/summary|time-tangle]]\n\n## Backlog\n- _(nothing)_\n",
        )
        .unwrap();
        let lane = current_lane_from_index(&p).unwrap();
        assert!(lane.contains("myapp"));
        assert!(lane.contains("time-tangle"));
        assert!(!lane.contains("nothing"));

        // an empty Current lane → None (so caller falls back)
        std::fs::write(
            p.project_index.as_ref().unwrap(),
            "## Current\n- \n\n## Backlog\n- x\n",
        )
        .unwrap();
        assert!(current_lane_from_index(&p).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn emit_recurring_surfaces_matching_active_only() {
        let content = "\
# Recurring

## Active
- [ ] timesheets (every:fri)
- [ ] rent (every:1st)
- [ ] standup (every:mon)
- [x] paused habit (every:fri)

## Done
- [x] old (done:2026-01-01)
";
        // 2026-07-10 is a Friday (not the 1st, not a Monday).
        let out = emit_recurring(content, d("2026-07-10"));
        assert_eq!(out.len(), 1);
        let line = &out[0];
        // token stripped, since:today stamped, checked/off-cadence/Done items excluded
        assert!(line.contains("timesheets"));
        assert!(!line.contains("every:"));
        assert!(line.contains("(0d) <!-- since:2026-07-10 -->"));
    }

    #[test]
    fn remove_section_strips_named_block() {
        let c = "# t\n\n## Focus\n- a\n\n## Watches\n- OK x\n\n---\nBacklogs: [[fun]]\n";
        let out = remove_section(c, "Watches");
        assert!(!out.contains("## Watches"));
        assert!(out.contains("## Focus"));
        assert!(out.contains("- a"));
        assert!(out.contains("Backlogs: [[fun]]"));
        // absent heading → unchanged
        assert_eq!(remove_section(c, "Nope"), c);
    }

    #[test]
    fn discover_watches_renders_and_sorts() {
        let dir = std::env::temp_dir().join(format!("notes-watch-{}", std::process::id()));
        let wdir = dir.join("watches");
        let sdir = dir.join("state");
        std::fs::create_dir_all(&wdir).unwrap();
        std::fs::create_dir_all(&sdir).unwrap();
        std::fs::write(
            wdir.join("api.yaml"),
            "name: api\ndescription: prod api\nprobe: http\ninterval: 5m\n",
        )
        .unwrap();
        std::fs::write(
            wdir.join("router.yaml"),
            "name: router\ndescription: 5ghz dfs\nprobe: command\ninterval: 15m\n",
        )
        .unwrap();
        std::fs::write(
            wdir.join("parked.yaml.paused"),
            "name: parked\ndescription: on hold\nprobe: metric\ninterval: 5m\n",
        )
        .unwrap();
        std::fs::write(sdir.join("api.state"), "OK\n").unwrap();
        std::fs::write(sdir.join("router.state"), "TRIP\n").unwrap();

        let mut p = profile(dir.to_str().unwrap());
        p.watches = Some(wdir.clone());
        p.watches_state = sdir.clone();

        let lines = discover_watches(&p);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "- TRIP router - 5ghz dfs (command, 15m)"); // unhealthy first
        assert_eq!(lines[1], "- OK api - prod api (http, 5m)");
        assert_eq!(lines[2], "- paused parked - on hold (metric, 5m)"); // paused last

        // unset → empty (opt-in gate)
        p.watches = None;
        assert!(discover_watches(&p).is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_inbox_lists_today_captures_and_self_hides() {
        let dir = std::env::temp_dir().join(format!("notes-inbox-{}", std::process::id()));
        let inbox = dir.join("inbox");
        let daily = dir.join("journal/daily");
        std::fs::create_dir_all(&inbox).unwrap();
        std::fs::create_dir_all(&daily).unwrap();
        let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
        let inbox_file = inbox.join(format!("{today}.md"));
        // second capture carries a session marker (as `notes inbox add` writes it)
        std::fs::write(&inbox_file, format!("# Inbox - {today}\n- 09:01 buy milk\n- 10:15 call bank <!-- session:abcd1234-ef56-7890-abcd-ef1234567890 -->\n")).unwrap();
        let note = daily.join(format!("{today}.md"));
        std::fs::write(&note, "# note\n\n## Due\n\n---\nBacklogs: [[fun]]\n").unwrap();

        let p = profile(dir.to_str().unwrap()); // profile() sets inbox = <root>/inbox
        let log = Logger::new(dir.join("log"), false);

        refresh_inbox(&p, &log, &note).unwrap();
        let out = std::fs::read_to_string(&note).unwrap();
        assert!(out.contains("## Inbox"));
        // rendered as checkbox tasks, not plain bullets
        assert!(out.contains("- [ ] 09:01 buy milk"));
        // session marker → short `(sess …)` suffix; raw comment stripped from the note
        assert!(out.contains("- [ ] 10:15 call bank (sess abcd1234)"));
        assert!(!out.contains("<!--"));
        // section sits above the footer
        assert!(out.find("## Inbox").unwrap() < out.find("---\nBacklogs:").unwrap());

        // check one off, add a new capture, re-run → the checkmark is preserved
        let ticked = out.replace("- [ ] 09:01 buy milk", "- [x] 09:01 buy milk");
        std::fs::write(&note, &ticked).unwrap();
        std::fs::write(
            &inbox_file,
            format!("# Inbox - {today}\n- 09:01 buy milk\n- 10:15 call bank\n- 11:30 new one\n"),
        )
        .unwrap();
        refresh_inbox(&p, &log, &note).unwrap();
        let out2 = std::fs::read_to_string(&note).unwrap();
        assert!(out2.contains("- [x] 09:01 buy milk")); // preserved
        assert!(out2.contains("- [ ] 10:15 call bank"));
        assert!(out2.contains("- [ ] 11:30 new one"));

        // empty inbox → section removed (self-hiding), idempotent
        std::fs::write(&inbox_file, format!("# Inbox - {today}\n")).unwrap();
        refresh_inbox(&p, &log, &note).unwrap();
        let out3 = std::fs::read_to_string(&note).unwrap();
        assert!(!out3.contains("## Inbox"));

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
