//! `notes today` — idempotent daily-note creation with carry-forward.
//!
//! Model: ONE task list in the note, fed by two files that differ by whether a task has a
//! time trigger.
//!   - **`## Focus`** = today's list. Unfinished items carry forward, day-stamped. There is
//!     no second list: `## Due` ("on deck", formerly `## Priority`) was removed because two
//!     lists in one note make every glance a merge, and anything a schedule surfaces IS
//!     today's work. A pre-migration note's Due items fold into Focus so nothing strands.
//!   - **backlog** (`fun.md`) = no time trigger. A someday list you pull from by hand.
//!   - **schedule** (`schedule.md`) = a time trigger. `[YYYY-MM-DD]` fires ONCE within
//!     `LEAD_DAYS` and the master line is consumed; `(every:…)` fires each matching day and
//!     the master line is kept. Tagging a surfaced task with a far-future date pushes it
//!     back out to the schedule, which is what makes the date a two-way verb.
//!
//! `scheduled.md` + `recurring.md` merged into `schedule.md`: they were two files for one
//! idea, differing only in consume-vs-keep, which the TOKEN already decides. Only one of
//! the three files was ever a backlog, which is why the footer used to list three
//! "backlogs" for two concepts.
//!
//! The note carries the human's own lists and the auto-rendered context sections
//! (`## Work`, `## Watches`, `## Comms`, `## Inbox`). It deliberately does NOT render the
//! project/agent board: that is regenerated as a FILE each run (`board.rs`) and reached from
//! the footer's `Board:` link. A `## Current Projects` block used to duplicate the lab
//! index here every morning; it was removed because the note is the FOCUS surface, and
//! anything pasted into it competes with the one list the human actually maintains — which
//! is exactly why the board is a link and not a section.

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
        // `backlog` is the name that describes it: the standing list with NO time trigger.
        "backlog" | "fun" => p.fun.clone(),
        // `scheduled`/`recurring`/`carryover` are back-compat aliases. Both files merged
        // into the one schedule, so every old name resolves there rather than to a path
        // that no longer exists — an editor alias pointing at a dead file fails silently.
        "schedule" | "scheduled" | "carryover" | "carry" | "recurring" => p.schedule.clone(),
        "zettel" => p.zettel.clone(),
        "meetings" => p.meetings.clone(),
        "index" => p.index.clone(),
        // The org's projects root. Added so `lab-roots.sh` can ASK for it rather than restating
        // it: that file hardcoded all four roots and its own comments named config.toml as "the
        // other place that has to know" — two declarations of one fact, where missing the second
        // makes a project silently resolve to "" and vanish from its bus. `?` because an org may
        // legitimately have no projects root, which is not the same as an unknown target.
        "projects" => p.projects.clone()?,
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
    migrate_log_to_daily(p, log)?;
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
    conform_legacy_sections(&note, log)?;

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
    // The project/agent board is regenerated as a FILE, not a section — the footer links it.
    // Same "render an external source each run" pattern as the sections above; the target
    // differs precisely so the note stays the human's focus surface. A failure here must
    // not abort the note, so it is logged and swallowed like the sweep below.
    if let Err(e) = crate::board::write(log) {
        log.warn("today", &format!("board refresh skipped: {e}"));
    }
    // Bucket `## Focus` by priority (Urgent/High/Low + Done) so a day whose items
    // just carried forward flat lands organized, matching the nvim on-save sweep. Idempotent,
    // writes only on change; a failure here never aborts note creation.
    let _ = crate::focus_sweep::sweep(p, log);
    Ok(())
}

fn create_note(p: &Profile, log: &Logger, today: NaiveDate, note: &Path) -> Result<()> {
    let today_s = today.format("%Y-%m-%d").to_string();

    let mut focus_keep: Vec<String> = Vec::new();
    let mut focus_defer: Vec<String> = Vec::new();

    if let Some(prev) = latest_prev(&p.daily, &today_s)? {
        let prev_date = file_date(&prev).unwrap_or(today);
        let mut content = fs::read_to_string(&prev)
            .with_context(|| format!("reading previous note {}", prev.display()))?;
        // Drop the trailing backlog footer before extracting sections. The last H2
        // (`## Due`, or legacy `## Priority`) sits directly above `\n---\nBacklogs:`,
        // and `capture` only stops at the next H2 — so without this the footer bleeds
        // into the carried section and re-seeds a stale `Backlogs:` line downstream.
        strip_backlog_footer(&mut content);

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

        // `## Due` is GONE — one task list, not two. It existed as "on deck" beside Focus's
        // "now", but the split cost more than it bought: two lists in one note means every
        // glance is a merge, and a surfaced item routinely sat in Due while the work it
        // named was already in Focus. Anything a schedule surfaces IS today's work.
        //
        // Still READ here (and its `## Priority` ancestor) so a pre-migration note does not
        // strand its items: they fold into Focus and carry forward normally from then on.
        let legacy_due =
            md::section_lines(&content, "Due").or_else(|| md::section_lines(&content, "Priority"));
        if let Some(lines) = legacy_due {
            let carried = carry(&lines, today, prev_date);
            let (keep, defer) = route_by_due(&carried, today);
            focus_keep.extend(keep);
            focus_defer.extend(defer);
        }
    }

    // The SCHEDULE: one pass surfaces both kinds of trigger into Focus — a `[date]` within
    // the lead window (consumed) and an `(every:…)` firing today (master line kept).
    let sched_before = fs::read_to_string(&p.schedule).unwrap_or_default();
    let (promoted, sched_pruned) = promote_schedule(&sched_before, today);
    let n_promoted = promoted.len();

    let mut focus_keys: std::collections::HashSet<String> =
        focus_keep.iter().map(|l| md::task_key(l)).collect();
    for pr in promoted {
        // Dedup against what already carried forward: a habit whose surfaced copy is still
        // open from yesterday must not land twice.
        if focus_keys.insert(md::task_key(&pr)) {
            focus_keep.push(pr);
        }
    }

    let mut s = String::new();
    s.push_str("---\n");
    s.push_str(&format!("date: {today_s}\n"));
    s.push_str("tags: [daily]\n");
    s.push_str("---\n\n");
    s.push_str(&format!("# {today_s}\n\n"));
    // No `## Current Projects` block. It was a static link list re-derived from the lab
    // index every morning, and the footer already carries `Projects: [[…/index]]` — the
    // same destination, one line instead of a section. The daily note is the human's
    // FOCUS surface; the project/agent board is a click away, not pasted in on top of it.
    s.push_str("## Focus\n");
    for l in &focus_keep {
        s.push_str(l);
        s.push('\n');
    }
    s.push_str("- [ ] \n\n");
    s.push_str("## Notes\n\n");

    md::write_atomic(note, &s).with_context(|| format!("writing {}", note.display()))?;
    if n_promoted > 0 {
        log.info(
            "today",
            &format!("surfaced {n_promoted} scheduled item(s) into Focus"),
        );
    }

    // Persist the schedule: pruned (consumed dates removed) + newly deferred items.
    let defers: Vec<String> = focus_defer;
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
        md::write_atomic(&p.schedule, &sched_after)
            .with_context(|| format!("writing {}", p.schedule.display()))?;
        if n_deferred > 0 {
            log.info(
                "today",
                &format!("deferred {n_deferred} item(s) to scheduled backlog"),
            );
        }
    }
    Ok(())
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

/// Surface today's due work out of the SCHEDULE's `## Active` in ONE pass, and return
/// `(surfaced, remaining_schedule_content)`.
///
/// This replaced two functions that differed by a single behaviour. `promote_scheduled`
/// matched a `[date]` token, emitted the task and REMOVED the line; `emit_recurring`
/// matched an `(every:…)` token, emitted the task and KEPT the file untouched. Same
/// input shape, same output section, same helpers — the only real difference is
/// consume-vs-keep, and that is decided by which token the line carries, not by which
/// file it sits in. Two files for one idea is what made the footer list three
/// "backlogs" for two concepts.
///
/// Surfaced lines have their trigger token stripped and a fresh day-count stamped, so a
/// surfaced copy is an ordinary task and the master line keeps its trigger.
fn promote_schedule(content: &str, today: NaiveDate) -> (Vec<String>, String) {
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
            // A `[date]` fires ONCE: emit it and drop the master line.
            if let Some(due) = md::find_due(line) {
                if due <= horizon {
                    promoted.push(md::stamp_line(&md::strip_due(line), today, today));
                    continue; // consumed
                }
            }
            // An `(every:…)` fires EVERY matching day: emit a copy, keep the master line.
            // Checked before the fall-through so a line carrying both tokens still lands
            // in exactly one branch — the date wins, because a dated one-off that also
            // repeats is a contradiction and the date is the more specific instruction.
            if md::recurs_on(line, today) {
                promoted.push(md::stamp_line(&md::strip_every(line), today, today));
                // no `continue`: the master line is kept below
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
    md::write_atomic(&note, &content)?;
    log.info("link-refs", &format!("linked {} ref(s)", links.len()));
    Ok(())
}

/// Add the backlog footer if not already present.
fn ensure_footer(p: &Profile, note: &Path) -> Result<()> {
    let original = fs::read_to_string(note)?;
    // REGENERATE, don't skip-if-present. The footer is generated content like `## Watches`,
    // and its links change when the system does — a note written before the `Board:` link
    // existed would otherwise never gain it, so a new link would only ever reach notes
    // created after the upgrade and today's note would sit stale until tomorrow.
    //
    // Safe because the footer is always LAST: nothing legitimately writes below it (the
    // warning in focus::add is about a bug that would, not a feature that does), and every
    // section refresh goes through `insert_before_footer`.
    let mut content = original.clone();
    strip_backlog_footer(&mut content);
    // Config-driven (`footer_links`), so the list is edited in config.toml, not here.
    // Each link carries its own LABEL: a Backlog (no time trigger) and a Schedule (has one)
    // are different kinds of thing, and the old single "Backlogs:" heading said otherwise.
    let backlogs = p
        .footer_links
        .iter()
        .map(|(label, b)| format!("{label}: [[{}]]", config::wikilink(&p.root, b)))
        .collect::<Vec<_>>()
        .join(" · ");
    if !content.ends_with('\n') {
        content.push('\n');
    }
    // Board first, then the index. The board is the one the human opens daily (it carries
    // the live wave + agent lane); the index is the slower "what projects exist" page.
    //
    // The board is linked against the VAULT, not this org's root: it is one cross-org file, so
    // an org-relative link would name a path inside that org that does not exist. That was the
    // live bug -- bnb's note read `Board: [[projects/board]]`, i.e. lab/bnb/projects/board.md,
    // which was never written. The editor puts both the org root and the vault on `path` (see
    // notes.nvim's gf setup), so the vault-relative form resolves from inside any org.
    let board_link = crate::board::board_path(p)
        .map(|b| format!(" · Board: [[{}]]", config::wikilink(&p.vault, &b)))
        .unwrap_or_default();
    // The agent lane gets its own link, or `agent-board.md` would be written by every
    // `notes today` and reachable from nothing.
    let agent_board_link = crate::board::agent_board_path(p)
        .map(|b| format!(" · Agent board: [[{}]]", config::wikilink(&p.vault, &b)))
        .unwrap_or_default();
    // The index, by contrast, IS this org's own -- so it stays org-relative, and gets a label
    // that says whose it is. Sitting unqualified beside the cross-org board, "Projects:" read
    // as the complete list while showing only one org's, which is how projects in another org
    // came to look missing.
    let projects_link = p
        .project_index
        .as_ref()
        .map(|pi| {
            format!(
                " · {} projects: [[{}]]",
                p.name,
                config::wikilink(&p.root, pi)
            )
        })
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
        "\n---\n{backlogs}{board_link}{agent_board_link}{projects_link}{inbox_link}\n"
    ));
    // Only write on change: `notes today` is idempotent and runs on every shell init, so a
    // no-op rewrite would churn the vault's mtime and its git sync every single time.
    if content != original {
        md::write_atomic(note, &content)?;
    }
    Ok(())
}

/// Byte offset of the note's link footer — the LAST `\n---\n` whose next line carries a
/// wikilink.
///
/// It used to be a literal search for `\n---\nBacklogs:`, which stopped working the moment
/// the footer's labels became config-driven (`Backlog: … · Schedule: …`). Matching on any
/// one label is no better, since a custom `footer_links` entry is labelled by its filename.
///
/// The `[[` test is what distinguishes the footer from the OTHER horizontal rule in a note:
/// `focus_sweep` writes `---` immediately above `### Done`, and that line has no wikilink.
/// Taking the LAST match keeps the footer's own identity even if a body line ever matched.
/// Old `Backlogs:` footers still resolve, so a pre-migration note migrates in place.
fn footer_idx(content: &str) -> Option<usize> {
    const RULE: &str = "\n---\n";
    let mut found = None;
    let mut from = 0;
    while let Some(rel) = content[from..].find(RULE) {
        let at = from + rel;
        let line_start = at + RULE.len();
        let line_end = content[line_start..]
            .find('\n')
            .map(|n| line_start + n)
            .unwrap_or(content.len());
        if content[line_start..line_end].contains("[[") {
            found = Some(at);
        }
        from = at + RULE.len();
    }
    found
}

/// Truncate a note at its link footer, leaving the body. Carry-forward reads the previous
/// note's sections, and the last H2 sits directly above the footer with no H2 between — so
/// stripping it here keeps the footer out of the carried section (and thus out of
/// tomorrow's note).
fn strip_backlog_footer(content: &mut String) {
    if let Some(idx) = footer_idx(content) {
        content.truncate(idx);
    }
}

pub(crate) fn insert_before_footer(content: &str, block: &str) -> String {
    if let Some(idx) = footer_idx(content) {
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

/// Render the Sentinel registry for the daily note: a one-line roster summary, then a
/// line per watch that actually needs the human (TRIP / ERROR / paused).
///
/// A healthy watch is deliberately NOT given a line. This section used to print all ten
/// with their full assertion and target, which is ~2000 characters of prose reporting
/// that nothing is wrong — in the note whose whole point is the human's focus. The
/// detail did not become less true, it just does not belong on a glance surface:
/// `watch-companion-loop list --long` is where a watch explains itself. The summary
/// line follows the `## Comms` pattern in the same note (counts up top, only what needs
/// you below).
///
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
        // The one fact a glance most needs and could never get here: 8 of 10 live
        // watches are `probe: command`, which has no `target`, so without `where` the
        // line cannot say which system it is even about.
        let wher = md::parse_yaml_scalar(&content, "where").unwrap_or_default();
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
        // `at: <where>` deliberately mirrors what a Sentinel notification says, so the
        // daily note and the page you get on your phone read the same way. `what` is
        // dropped here: on a line you only see because something is WRONG, the standing
        // assertion is the least useful part -- you want the name, the system, and how
        // stale the signal is.
        let mut line = format!("- {state} {name}");
        if !wher.is_empty() {
            line.push_str(&format!(" - at: {wher}"));
        }
        line.push_str(&format!(" ({probe}, {interval})"));
        rows.push((rank, name, line));
    }
    if rows.is_empty() {
        return Vec::new();
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));

    // Counts come from the RANKS, not from re-reading state, so the summary can never
    // disagree with the lines under it.
    let total = rows.len();
    let bad = rows.iter().filter(|r| r.0 == 0).count();
    let paused = rows.iter().filter(|r| r.0 == 2).count();
    let healthy = total - bad - paused;

    let mut parts = vec![format!("{healthy} OK")];
    if bad > 0 {
        parts.push(format!("{bad} tripped"));
    }
    if paused > 0 {
        parts.push(format!("{paused} paused"));
    }
    let summary = parts.join(", ");
    let mut out = vec![format!("_{total} watches - {summary}_")];
    // Only what needs the human. A healthy watch is accounted for in the count above and
    // says the rest of itself in `watch-companion-loop list`.
    out.extend(rows.into_iter().filter(|r| r.0 != 1).map(|(_, _, l)| l));
    out
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
    migrate_to_schedule(p, log)?;
    ensure_backlog_file(
        &p.schedule,
        "Schedule",
        "schedule",
        "Every task with a time trigger, surfacing into a daily note's Focus when it fires. `[MM-DD-YY]` fires ONCE and the line is consumed; `(every:…)` fires each matching day and the line stays. Cadences: every:fri · every:mon,thu · every:weekday · every:day · every:1st · every:last.",
        log,
    )?;
    Ok(())
}

/// One-time migration: `scheduled.md` + `recurring.md` -> `schedule.md`.
///
/// They were two files for one idea. A `[date]` line fires once and is consumed; an
/// `(every:…)` line fires each cycle and is kept — that is a difference in the TOKEN, and
/// both already surfaced through the same helpers into the same section. Concatenating
/// their `## Active` bodies is therefore lossless: every line keeps the token that decides
/// its behaviour.
///
/// Idempotent and non-destructive. It runs only while `schedule.md` is absent, and the two
/// sources are RENAMED aside rather than deleted, so a bad merge is recoverable by hand.
fn migrate_to_schedule(p: &Profile, log: &Logger) -> Result<()> {
    if p.schedule.exists() {
        return Ok(());
    }
    let sources = [&p.scheduled, &p.recurring];
    if !sources.iter().any(|s| s.exists()) {
        return Ok(()); // fresh vault — ensure_backlog_file scaffolds an empty schedule
    }
    let mut active: Vec<String> = Vec::new();
    let mut done: Vec<String> = Vec::new();
    for src in sources {
        let Ok(c) = fs::read_to_string(src) else {
            continue;
        };
        // Section-aware, not a blind concat: a blind one would fold `## Done` history into
        // `## Active` and resurrect every finished habit as live work tomorrow morning.
        active.extend(md::section_lines(&c, "Active").unwrap_or_default());
        done.extend(md::section_lines(&c, "Done").unwrap_or_default());
    }
    let keep = |v: Vec<String>| -> Vec<String> {
        v.into_iter().filter(|l| md::is_task(l)).collect()
    };
    let (active, done) = (keep(active), keep(done));

    if let Some(parent) = p.schedule.parent() {
        fs::create_dir_all(parent)?;
    }
    let body = format!(
        "---\ntags: [schedule]\n---\n\n# Schedule\n\n\
         Every task with a time trigger, surfacing into a daily note's Focus when it fires. \
         `[MM-DD-YY]` fires ONCE and the line is consumed; `(every:…)` fires each matching \
         day and the line stays. Cadences: every:fri · every:mon,thu · every:weekday · \
         every:day · every:1st · every:last.\n\n## Active\n{}\n\n## Done\n{}\n",
        active.join("\n"),
        done.join("\n"),
    );
    md::write_atomic(&p.schedule, &body)?;

    // Rename aside rather than delete: the merge is mechanical but the data is the user's.
    for src in sources {
        if src.exists() {
            let bak = src.with_extension("md.premerge");
            let _ = fs::rename(src, &bak);
        }
    }
    log.info(
        "backlog",
        &format!(
            "merged scheduled + recurring → {} ({} active, {} done; sources kept as .md.premerge)",
            p.schedule.display(),
            active.len(),
            done.len()
        ),
    );
    Ok(())
}

/// Conform an EXISTING note to the current shape: fold legacy `## Due` / `## Priority` items
/// into `## Focus`, then drop the sections an older build wrote.
///
/// `create_note` already does this, but only for a note it writes itself. A note created
/// earlier the same day by a stale binary never passes through it, so the note the human
/// actually opens keeps `## Current Projects` and an empty `## Due` no matter how current the
/// engine is. That gap is why a machine one build behind produced a visibly different daily.
///
/// Idempotent, and a no-op on a note that is already clean.
fn conform_legacy_sections(note: &Path, log: &Logger) -> Result<()> {
    let original = fs::read_to_string(note)
        .with_context(|| format!("reading {}", note.display()))?;

    let mut folded: Vec<String> = Vec::new();
    for heading in ["Due", "Priority"] {
        if let Some(lines) = md::section_lines(&original, heading) {
            folded.extend(lines.into_iter().filter(|l| md::is_open_task(l)));
        }
    }
    // With nowhere to fold to, leave the note alone rather than delete the human's tasks.
    if !folded.is_empty() && !original.lines().any(|l| l.trim() == "## Focus") {
        return Ok(());
    }

    let mut content = original.clone();
    for heading in ["Current Projects", "Due", "Priority"] {
        content = remove_section(&content, heading);
    }
    if !folded.is_empty() {
        content = insert_into_focus(&content, &folded);
    }
    if content == original {
        return Ok(());
    }
    md::write_atomic(note, &content)?;
    log.info(
        "today",
        &format!("conformed legacy sections ({} item(s) folded into Focus)", folded.len()),
    );
    Ok(())
}

/// Put lines directly under the `## Focus` heading. The priority sweep at the end of `run`
/// buckets them into their lanes afterwards, so no ordering is decided here.
fn insert_into_focus(content: &str, lines: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut placed = false;
    for l in content.lines() {
        out.push(l.to_string());
        if !placed && l.trim() == "## Focus" {
            out.extend(lines.iter().cloned());
            placed = true;
        }
    }
    if !placed {
        return content.to_string();
    }
    let mut s = out.join("\n");
    if content.ends_with('\n') {
        s.push('\n');
    }
    s
}

/// One-time migration: `log/` -> `daily/`, and `log_archive/` -> `daily_archive/`.
///
/// One engine writes one shape of note, but the org default named its directory `log/` while
/// personal named the same thing `daily/`. A job vault therefore never looked like the journal
/// it was generated from, and every doc had to say "log (daily)". The org default is now
/// `daily`; this carries an existing directory across so the flip does not leave a fresh empty
/// dir sitting beside the full one.
///
/// Must run before `run` creates `p.daily`: that call would plant the very directory whose
/// absence is the guard here.
fn migrate_log_to_daily(p: &Profile, log: &Logger) -> Result<()> {
    migrate_legacy_dir(&p.daily, "daily", "log", log)?;
    migrate_legacy_dir(&p.archive, "daily_archive", "log_archive", log)?;
    Ok(())
}

/// Rename `<parent>/<legacy>` to `dest`, but only when `dest` is on the new default name,
/// does not exist yet, and the legacy sibling does. Every other shape is left alone, which is
/// what makes this safe on a machine whose config still pins the old name: a profile with
/// `daily = "log"` keeps its `log/`, and one already migrated is a no-op.
fn migrate_legacy_dir(dest: &Path, expected: &str, legacy: &str, log: &Logger) -> Result<()> {
    if dest.file_name().and_then(|s| s.to_str()) != Some(expected) || dest.exists() {
        return Ok(());
    }
    let Some(parent) = dest.parent() else {
        return Ok(());
    };
    let src = parent.join(legacy);
    if !src.is_dir() {
        return Ok(());
    }
    fs::rename(&src, dest)
        .with_context(|| format!("renaming {} -> {}", src.display(), dest.display()))?;
    log.info(
        "migrate",
        &format!("{} -> {}", src.display(), dest.display()),
    );
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
            schedule: r.join("journal/schedule.md"),
            footer_links: vec![
                ("Backlog".into(), r.join("journal/backlogs/fun.md")),
                ("Schedule".into(), r.join("journal/schedule.md")),
            ],
            watches: None,
            watches_state: r.join("state/watch-companion"),
            clickup_list: None,
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
            vault: PathBuf::from(root),
            board: PathBuf::from(root).join("lab/projects/board.md"),
            inbox: r.join("inbox"),
            tag_scan: Vec::new(),
            state_dir: r.join(".state"),
            log_file: r.join(".state/journal.log"),
        }
    }

    /// A note left behind by an older build: the dead headings go, the human's Due items
    /// survive by folding into Focus, and a second pass changes nothing.
    #[test]
    fn a_stale_note_is_conformed_and_its_due_items_survive() {
        let dir = std::env::temp_dir().join(format!("notes-conform-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let note = dir.join("2026-08-28.md");
        fs::write(
            &note,
            "# 2026-08-28\n\n## Current Projects\n- [[projects/current/x|x]]\n\n\
             ## Focus\n- [ ] already here\n\n## Notes\n\n## Due\n- [ ] carried from due\n- [x] finished\n\n\
             ---\nSchedule: [[schedule]]\n",
        )
        .unwrap();
        let log = Logger::new(dir.join("log.txt"), false);

        conform_legacy_sections(&note, &log).unwrap();
        let out = fs::read_to_string(&note).unwrap();

        assert!(!out.contains("## Current Projects"), "static link list dropped");
        assert!(!out.contains("## Due"), "second list dropped");
        assert!(out.contains("- [ ] carried from due"), "open item folded, not deleted");
        assert!(!out.contains("- [x] finished"), "completed item not resurrected");
        assert!(out.contains("- [ ] already here"), "existing focus kept");
        assert!(out.contains("Schedule: [[schedule]]"), "footer intact");

        conform_legacy_sections(&note, &log).unwrap();
        assert_eq!(fs::read_to_string(&note).unwrap(), out, "idempotent");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Nowhere to fold to means leave it alone. Removing `## Due` here would silently eat
    /// the only copy of those tasks.
    #[test]
    fn a_note_without_focus_is_left_untouched() {
        let dir = std::env::temp_dir().join(format!("notes-conform-b-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let note = dir.join("2026-08-28.md");
        let body = "# 2026-08-28\n\n## Due\n- [ ] the only copy\n";
        fs::write(&note, body).unwrap();
        let log = Logger::new(dir.join("log.txt"), false);

        conform_legacy_sections(&note, &log).unwrap();

        assert_eq!(fs::read_to_string(&note).unwrap(), body);
        let _ = fs::remove_dir_all(&dir);
    }

    /// An org profile on the new default: `log/` carries across to `daily/`, notes and all.
    #[test]
    fn a_legacy_log_dir_migrates_to_daily() {
        let dir = std::env::temp_dir().join(format!("notes-mig-a-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut p = profile(dir.to_str().unwrap());
        p.daily = dir.join("daily");
        p.archive = dir.join("daily_archive");
        fs::create_dir_all(dir.join("log")).unwrap();
        fs::write(dir.join("log/2026-06-18.md"), "# 2026-06-18\n").unwrap();
        fs::create_dir_all(dir.join("log_archive/2026")).unwrap();
        let log = Logger::new(dir.join("log.txt"), false);

        migrate_log_to_daily(&p, &log).unwrap();

        assert!(dir.join("daily/2026-06-18.md").exists(), "note carried over");
        assert!(!dir.join("log").exists(), "legacy dir is gone, not copied");
        assert!(dir.join("daily_archive/2026").is_dir(), "archive migrated too");
        let _ = fs::remove_dir_all(&dir);
    }

    /// A profile that still pins `daily = "log"` keeps its `log/`. This is what makes the
    /// default flip safe on a machine whose gitignored config has not been collapsed yet.
    #[test]
    fn a_pinned_log_dir_is_left_alone() {
        let dir = std::env::temp_dir().join(format!("notes-mig-b-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut p = profile(dir.to_str().unwrap());
        p.daily = dir.join("log");
        fs::create_dir_all(dir.join("log")).unwrap();
        fs::write(dir.join("log/2026-06-18.md"), "x").unwrap();
        let log = Logger::new(dir.join("log.txt"), false);

        migrate_log_to_daily(&p, &log).unwrap();

        assert!(dir.join("log/2026-06-18.md").exists(), "pinned dir untouched");
        assert!(!dir.join("daily").exists(), "no daily dir invented");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Already migrated, or a personal-shaped vault where both names happen to exist: the
    /// destination wins and the legacy dir is left for the human, never merged or clobbered.
    #[test]
    fn an_existing_daily_dir_is_never_clobbered() {
        let dir = std::env::temp_dir().join(format!("notes-mig-c-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut p = profile(dir.to_str().unwrap());
        p.daily = dir.join("daily");
        fs::create_dir_all(dir.join("daily")).unwrap();
        fs::write(dir.join("daily/keep.md"), "keep").unwrap();
        fs::create_dir_all(dir.join("log")).unwrap();
        fs::write(dir.join("log/old.md"), "old").unwrap();
        let log = Logger::new(dir.join("log.txt"), false);

        migrate_log_to_daily(&p, &log).unwrap();

        assert_eq!(fs::read_to_string(dir.join("daily/keep.md")).unwrap(), "keep");
        assert!(dir.join("log/old.md").exists(), "legacy left for the human");
        let _ = fs::remove_dir_all(&dir);
    }

    /// The personal profile pins `journal/daily`, whose sibling `journal/log` never existed.
    #[test]
    fn the_personal_profile_is_a_no_op() {
        let dir = std::env::temp_dir().join(format!("notes-mig-d-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = profile(dir.to_str().unwrap()); // daily = journal/daily, archive = journal/daily_archive
        fs::create_dir_all(dir.join("log")).unwrap(); // a decoy at the ROOT, not the parent
        let log = Logger::new(dir.join("log.txt"), false);

        migrate_log_to_daily(&p, &log).unwrap();

        assert!(!dir.join("journal/daily").exists(), "nothing created");
        assert!(dir.join("log").is_dir(), "root-level decoy untouched");
        let _ = fs::remove_dir_all(&dir);
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

    /// The daily note is the human's FOCUS surface: no `## Current Projects` block, and the
    /// lab index still reachable in one click from the footer.
    ///
    /// Both halves matter. Dropping the section alone would strand the destination if the
    /// footer link were ever conditional, so the reachability is asserted in the same test
    /// rather than assumed — that link is now the ONLY path from the note to the projects.
    #[test]
    fn a_fresh_note_has_no_current_projects_but_still_reaches_the_index() {
        let dir = std::env::temp_dir().join(format!("notes-slim-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let projects = dir.join("lab/projects/current");
        std::fs::create_dir_all(&projects).unwrap();
        std::fs::create_dir_all(dir.join("journal/daily")).unwrap();
        let mut p = profile(dir.to_str().unwrap());
        p.projects = Some(projects.clone());
        p.project_index = Some(projects.parent().unwrap().join("index.md"));
        // A populated index: under the old behaviour its `## Current` lane was copied into
        // the note verbatim, so this is exactly the fixture that used to produce a block.
        std::fs::write(
            p.project_index.as_ref().unwrap(),
            "## Current\n- [[lab/projects/current/myapp/README|myapp]]\n",
        )
        .unwrap();

        let log = Logger::new(dir.join("log"), false);
        let note = dir.join("journal/daily/2026-08-05.md");
        create_note(&p, &log, d("2026-08-05"), &note).unwrap();
        ensure_footer(&p, &note).unwrap();
        let out = std::fs::read_to_string(&note).unwrap();

        assert!(!out.contains("## Current Projects"), "section is gone:\n{out}");
        assert!(
            !out.contains("myapp"),
            "the index lane must not be copied in:\n{out}"
        );
        // The index link NAMES its org. Unqualified, "Projects:" sat beside the cross-org
        // "Board:" and read as the complete list while showing one org's -- which is how
        // projects living in another org came to look missing.
        assert!(
            out.contains("test projects: [[lab/projects/index]]"),
            "footer links the index, scoped to its org:\n{out}"
        );
        // The note opens straight into the human's own list.
        assert!(out.contains("## Focus"));

        let _ = std::fs::remove_dir_all(&dir);
    }

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

    /// The board is ONE file for every org, so an org whose root is not the vault must still
    /// link a path that resolves. The live bug: bnb (root `lab/bnb`) wrote
    /// `Board: [[projects/board]]`, i.e. `lab/bnb/projects/board.md`, which was never written --
    /// only `lab/projects/board.md` ever existed. An org-relative link cannot name a file
    /// outside its own org, so the board is addressed against the vault.
    #[test]
    fn the_board_link_resolves_from_an_org_that_is_not_the_vault_root() {
        let mut p = profile("/vault");
        p.root = PathBuf::from("/vault/lab/bnb"); // a nested org, like bnb
        p.vault = PathBuf::from("/vault");
        p.board = PathBuf::from("/vault/lab/projects/board.md");

        let link = config::wikilink(&p.vault, &crate::board::board_path(&p).unwrap());
        assert_eq!(link, "lab/projects/board");
        // ...and specifically NOT the org-relative form, which named a file that never existed.
        assert_ne!(link, "projects/board");
    }

    /// Every org resolves the SAME board. If this can differ per profile, `write()` and the
    /// footer can disagree again -- which is exactly how one file came to exist while every
    /// other org linked one that did not.
    #[test]
    fn the_board_is_one_address_for_every_org() {
        let mut a = profile("/vault");
        a.root = PathBuf::from("/vault/lab/bnb");
        let mut b = profile("/vault");
        b.root = PathBuf::from("/vault/employment/jobs/acme");
        assert_eq!(board_path_of(&a), board_path_of(&b));
        fn board_path_of(p: &Profile) -> PathBuf {
            crate::board::board_path(p).unwrap()
        }
    }

    /// `lab-roots.sh` builds the whole set of org bus roots out of this one target, so it is a
    /// cross-repo contract, not an editor convenience. It used to hardcode the four roots itself
    /// and admit in a comment that config.toml was "the other place that has to know"; if this
    /// target regresses, that file has no way to ask and every org's bus goes quiet.
    #[test]
    fn resolve_projects_target_is_the_org_bus_root() {
        let mut p = profile("/vault");
        p.projects = Some(PathBuf::from("/vault/projects/current"));
        assert_eq!(
            resolve_path(&p, "projects").unwrap(),
            PathBuf::from("/vault/projects/current")
        );
    }

    /// An org with no projects root is a real state, and it must read as "no bus here" rather
    /// than as an unknown target -- lab_roots skips it, instead of aborting the whole sweep.
    #[test]
    fn resolve_projects_is_none_when_the_org_has_no_projects_root() {
        let mut p = profile("/vault");
        p.projects = None;
        assert!(resolve_path(&p, "projects").is_none());
        // ...while a sibling target on the same profile still resolves, so this is proving the
        // None comes from `projects` being unset and not from a broken fixture.
        assert!(resolve_path(&p, "root").is_some());
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
    fn promote_schedule_surfaces_due_and_overdue() {
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
        let (promoted, remaining) = promote_schedule(content, d("2026-06-30"));
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

    /// The whole point of the merge: ONE file, ONE pass, and the TOKEN decides whether the
    /// master line survives. A `[date]` is consumed; an `(every:…)` is kept. Getting this
    /// backwards either loses a one-off silently or resurrects a habit as a duplicate every
    /// single morning, and both failures are invisible until the file has rotted.
    #[test]
    fn a_date_is_consumed_and_a_cadence_is_kept_in_one_pass() {
        let content = "\
# Schedule

## Active
- [ ] timesheets (every:fri)
- [ ] rent (every:1st)
- [ ] standup (every:mon)
- [x] paused habit (every:fri)
- [ ] one-off thing [2026-07-10]
- [ ] far future [2027-01-01]

## Done
- [x] old (done:2026-01-01)
";
        // 2026-07-10 is a Friday, not the 1st, not a Monday.
        let (out, remaining) = promote_schedule(content, d("2026-07-10"));

        let surfaced: Vec<&str> = out.iter().map(|s| s.as_str()).collect();
        assert_eq!(surfaced.len(), 2, "friday habit + today's one-off: {surfaced:?}");
        assert!(surfaced.iter().any(|l| l.contains("timesheets")));
        assert!(surfaced.iter().any(|l| l.contains("one-off thing")));
        // triggers stripped, day-stamped
        assert!(!out.iter().any(|l| l.contains("every:") || l.contains("[2026-")));
        assert!(out.iter().all(|l| l.contains("(0d) <!-- since:2026-07-10 -->")));

        // the cadence line SURVIVES so it fires again next Friday...
        assert!(remaining.contains("- [ ] timesheets (every:fri)"));
        // ...and the one-off is GONE, so it never fires twice
        assert!(!remaining.contains("one-off thing"));
        // untouched: off-cadence, checked, far-future, and the whole Done section
        assert!(remaining.contains("rent (every:1st)"));
        assert!(remaining.contains("- [x] paused habit"));
        assert!(remaining.contains("far future [2027-01-01]"));
        assert!(remaining.contains("- [x] old (done:2026-01-01)"));
    }

    /// The footer marker must survive its own labels becoming config-driven, and must not
    /// confuse the `---` that `focus_sweep` writes above `### Done` for the footer. Picking
    /// that one would truncate the note at Done and delete everything below it — Notes,
    /// Work, Watches, Comms and the footer itself — every single morning.
    #[test]
    fn footer_marker_finds_the_link_footer_not_the_done_rule() {
        let with_done = "# t\n\n## Focus\n- [ ] a\n\n---\n### Done\n- [x] b\n\n## Notes\n\n---\nBacklog: [[journal/backlogs/fun]] · Schedule: [[journal/schedule]]\n";
        let idx = footer_idx(with_done).expect("footer found");
        assert!(
            with_done[idx..].contains("Backlog: [["),
            "picked the wrong rule: {:?}",
            &with_done[idx..idx + 20]
        );
        assert!(
            with_done[..idx].contains("### Done"),
            "Done must survive the truncation"
        );

        // A pre-migration footer still resolves, so an old note migrates in place.
        let legacy = "# t\n\n## Due\n- [ ] x\n\n---\nBacklogs: [[journal/backlogs/fun]]\n";
        assert!(footer_idx(legacy).is_some());

        // A note with no footer yet must report none rather than guessing.
        assert!(footer_idx("# t\n\n## Focus\n- [ ] a\n").is_none());
        // ...including one whose only rule is the Done separator.
        assert!(footer_idx("# t\n\n## Focus\n\n---\n### Done\n- [x] b\n").is_none());
    }

    /// The merge must be LOSSLESS and section-aware. A blind concat would fold `## Done`
    /// history into `## Active` and resurrect every finished habit as live work.
    #[test]
    fn migration_merges_both_files_section_aware_and_keeps_the_sources() {
        let dir = std::env::temp_dir().join(format!("notes-mig-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut p = profile(dir.to_str().unwrap());
        p.scheduled = dir.join("backlogs/scheduled.md");
        p.recurring = dir.join("backlogs/recurring.md");
        p.schedule = dir.join("schedule.md");
        std::fs::create_dir_all(dir.join("backlogs")).unwrap();
        std::fs::write(
            &p.scheduled,
            "# Scheduled\n\n## Active\n- [ ] pay tax [2026-09-01]\n\n## Done\n- [x] old one\n",
        )
        .unwrap();
        std::fs::write(
            &p.recurring,
            "# Recurring\n\n## Active\n- [ ] water plants (every:sun)\n\n## Done\n- [x] old habit\n",
        )
        .unwrap();

        let log = Logger::new(dir.join("log"), false);
        migrate_to_schedule(&p, &log).unwrap();
        let out = std::fs::read_to_string(&p.schedule).unwrap();

        let active = &out[out.find("## Active").unwrap()..out.find("## Done").unwrap()];
        assert!(active.contains("pay tax [2026-09-01]"), "{out}");
        assert!(active.contains("water plants (every:sun)"), "{out}");
        // the finished items stayed finished
        assert!(!active.contains("old one"), "Done bled into Active:\n{out}");
        assert!(!active.contains("old habit"), "Done bled into Active:\n{out}");
        assert!(out.contains("- [x] old one") && out.contains("- [x] old habit"));

        // sources renamed aside, not deleted — the data is the user's
        assert!(!p.scheduled.exists() && !p.recurring.exists());
        assert!(dir.join("backlogs/scheduled.md.premerge").exists());
        assert!(dir.join("backlogs/recurring.md.premerge").exists());

        // idempotent: a second run must not double anything
        let before = out.clone();
        migrate_to_schedule(&p, &log).unwrap();
        assert_eq!(std::fs::read_to_string(&p.schedule).unwrap(), before);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `## Due` is gone, and a pre-migration note's Due items must fold into Focus rather
    /// than be stranded — otherwise the upgrade silently eats a list of real tasks.
    #[test]
    fn due_is_gone_and_its_legacy_items_fold_into_focus() {
        let dir = std::env::temp_dir().join(format!("notes-due-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("journal/daily")).unwrap();
        let p = profile(dir.to_str().unwrap());
        std::fs::write(
            dir.join("journal/daily/2026-08-04.md"),
            "# 2026-08-04\n\n## Focus\n- [ ] my thing\n\n## Notes\n\n## Due\n- [ ] water plants\n- [ ] pay rent\n",
        )
        .unwrap();

        let log = Logger::new(dir.join("log"), false);
        let note = dir.join("journal/daily/2026-08-05.md");
        create_note(&p, &log, d("2026-08-05"), &note).unwrap();
        let out = std::fs::read_to_string(&note).unwrap();

        assert!(!out.contains("## Due"), "Due section is gone:\n{out}");
        let focus = &out[out.find("## Focus").unwrap()..out.find("## Notes").unwrap()];
        assert!(focus.contains("my thing"), "{out}");
        assert!(focus.contains("water plants"), "legacy Due item stranded:\n{out}");
        assert!(focus.contains("pay rent"), "legacy Due item stranded:\n{out}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A line carrying BOTH tokens is a contradiction the format allows. It must land in
    /// exactly one branch or it surfaces twice; the date wins as the more specific
    /// instruction, and the line is consumed.
    #[test]
    fn a_line_with_both_triggers_fires_once_and_is_consumed() {
        let content = "# S\n\n## Active\n- [ ] weird [2026-07-10] (every:fri)\n\n## Done\n";
        let (out, remaining) = promote_schedule(content, d("2026-07-10"));
        assert_eq!(out.len(), 1, "must not surface twice: {out:?}");
        assert!(!remaining.contains("weird"), "date wins, so it is consumed");
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
        // Summary, then only what needs the human: the TRIP and the paused one. The
        // healthy `api` watch is a number in the summary, not a line -- ten healthy
        // watches printing their full assertion is what made this section unreadable.
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "_3 watches - 1 OK, 1 tripped, 1 paused_");
        assert_eq!(lines[1], "- TRIP router (command, 15m)"); // unhealthy first
        assert_eq!(lines[2], "- paused parked (metric, 5m)"); // paused last
        assert!(!lines.iter().any(|l| l.contains("- OK api")));

        // unset → empty (opt-in gate)
        p.watches = None;
        assert!(discover_watches(&p).is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn discover_watches_folds_block_scalars_and_surfaces_only_the_unhealthy() {
        // The regression this pins: every fixture above uses a plain one-line
        // `description:`, and real manifests overwhelmingly do not — a long description
        // is exactly when you reach for `>-`. So the daily note rendered
        // `- TRIP deploy-drift - >- (command, 6h)` for most watches, printing the YAML
        // marker as if it were the text, and no test noticed because none used a block.
        let dir = std::env::temp_dir().join(format!("notes-watch-blk-{}", std::process::id()));
        let wdir = dir.join("watches");
        let sdir = dir.join("state");
        std::fs::create_dir_all(&wdir).unwrap();
        std::fs::create_dir_all(&sdir).unwrap();

        // A current manifest: one-line `what` + `where`, with the essay in `description`.
        std::fs::write(
            wdir.join("drift.yaml"),
            "name: drift\n\
             what: >-\n  dotfiles-drift reports nothing: no repo behind main, no mirror adrift.\n\
             why: >-\n  A merged file goes live only when stow has run.\n\
             where: >-\n  ~/.dotfiles and the private overlay\n\
             description: >-\n  Trip when what is MERGED stops being what is RUNNING.\n\n  A second paragraph that must not leak into the line.\n\
             probe: command\ninterval: 6h\n",
        )
        .unwrap();
        // A legacy manifest: block `description`, no legibility fields at all.
        std::fs::write(
            wdir.join("legacy.yaml"),
            "name: legacy\ndescription: |-\n  first line\n  second line\nprobe: http\ninterval: 5m\n",
        )
        .unwrap();
        std::fs::write(sdir.join("drift.state"), "TRIP\n").unwrap();
        std::fs::write(sdir.join("legacy.state"), "OK\n").unwrap();

        let mut p = profile(dir.to_str().unwrap());
        p.watches = Some(wdir.clone());
        p.watches_state = sdir.clone();

        let lines = discover_watches(&p);
        // Summary + the one tripped watch; the healthy legacy one is just a count.
        assert_eq!(lines.len(), 2);

        // The marker must never reach the note. This is the assertion that fails on the
        // old parser, and the only one that really matters.
        assert!(!lines.iter().any(|l| l.contains(">-") || l.contains("|-")));

        assert_eq!(lines[0], "_2 watches - 1 OK, 1 tripped_");
        // `where` rides along as `at:` -- for a `probe: command` watch it is the only
        // thing naming the system, since a command watch carries no `target`.
        assert_eq!(
            lines[1],
            "- TRIP drift - at: ~/.dotfiles and the private overlay (command, 6h)"
        );

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
    fn promote_schedule_noop_when_all_far() {
        let content = "## Active\n- [ ] later [2027-01-01]\n\n## Done\n";
        let (promoted, remaining) = promote_schedule(content, d("2026-06-30"));
        assert!(promoted.is_empty());
        assert_eq!(remaining, content);
    }
}
