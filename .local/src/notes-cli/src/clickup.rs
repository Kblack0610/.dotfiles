//! `notes clickup sync` — mirror in-progress ClickUp tickets assigned to me into today's
//! `## Focus`, so "what I'm doing for the day" reflects the tracker. This is the ClickUp
//! analogue of the Vikunja `in_progress()` mirror lab-sync does, but it lands the tickets as
//! real, actionable Focus items rather than a read-only feed.
//!
//! Two decoupled halves, mirroring the Sentinel/`## Watches` split (HTTP out of the note
//! path):
//!   1. FETCH — a separate `notes-clickup-fetch` script queries ClickUp over REST (keychain
//!      token) and writes a TSV cache; it self-bounds with `curl --max-time`. Never touches
//!      the note.
//!   2. RECONCILE (this module) — reads the cache and merges tickets into `## Focus` via the
//!      shared `md` helpers, then sweeps them into priority lanes. Runs in the foreground,
//!      when the user asks — never on a background timer clobbering an open editor buffer.
//!
//! Dedup is two-tier because `stamp_line` drops trailing comments on the overnight carry:
//! primary match is the `<!-- cu:ID -->` marker (same-day), fallback is `md::task_key`
//! derived from the ClickUp title (survives the carry). A matched ticket is left ALONE — the
//! user's checkbox/priority edits are never clobbered. Only genuinely-new tickets are added.
//!
//! Opt-in: no-op when the profile has no `clickup_list` (only the work profile sets it), the
//! same guard `refresh_watches`/`refresh_work` use so a machine/profile without it is inert.

use crate::config::Profile;
use crate::daily;
use crate::focus_sweep;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use chrono::Local;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::process::Command;

/// The section the bridge writes into (the daily cockpit's active-task lane).
const FOCUS: &str = "Focus";

/// The fetch helper, resolved on PATH (installed at `~/.dotfiles/.local/bin`). It owns the
/// ClickUp REST call + keychain token; this module never speaks HTTP, so the public notes
/// crate carries no ClickUp auth or network code (and no extra deps).
const FETCH_BIN: &str = "notes-clickup-fetch";

/// Board status names the write-back targets (list 901713708011 vocabulary). Board-specific;
/// promote to config if a second board with different status names ever uses the bridge.
/// A note `[/]` maps to in-progress, a `[x]` to the closed/done status.
const IN_PROGRESS_STATUS: &str = "in progress";
const DONE_STATUS: &str = "completed";

/// One in-progress ClickUp ticket, as read from the TSV cache. `status` is ClickUp's current
/// status word at last fetch — the baseline the write-back delta compares the note against.
struct Ticket {
    id: String,
    priority: String, // clickup priority word: urgent|high|normal|low|"" (none)
    status: String,   // clickup status word at last fetch (e.g. "in progress")
    title: String,
}

/// Map a ClickUp priority word to the note's priority hashtag. The note model has three
/// levels (`md::PRIORITIES`: urgent/high/low); ClickUp's "normal" (its default) has no
/// lane, so it maps to `""` (no tag) like "none" — the task sweeps into the untagged top
/// bucket rather than a lane.
fn priority_tag(word: &str) -> &'static str {
    match word.trim().to_lowercase().as_str() {
        "urgent" => "#urgent",
        "high" => "#high",
        "low" => "#low",
        _ => "", // "normal" / "none" / unknown -> untagged
    }
}

/// Parse the TSV cache. Phase 2 format is 4-col `id<TAB>priority<TAB>status<TAB>title`; a
/// legacy 3-col `id<TAB>priority<TAB>title` line (written by a Phase-1 fetch) is still read,
/// with an empty status. Blank/`#`-comment lines are skipped; a row missing the id or title is
/// dropped rather than injecting a malformed task. Tolerant by design — a separate tool writes it.
fn parse_cache(text: &str) -> Vec<Ticket> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim_end_matches(['\r', '\n']);
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let cols: Vec<&str> = line.splitn(4, '\t').collect();
        let (id, priority, status, title) = match cols.as_slice() {
            [id, priority, status, title] => (*id, *priority, *status, *title),
            [id, priority, title] => (*id, *priority, "", *title), // legacy Phase-1 cache
            _ => continue,
        };
        let (id, title) = (id.trim(), title.trim());
        if id.is_empty() || title.is_empty() {
            continue;
        }
        out.push(Ticket {
            id: id.to_string(),
            priority: priority.trim().to_string(),
            status: status.trim().to_string(),
            title: title.to_string(),
        });
    }
    out
}

/// Rewrite the 4-col TSV cache from `tickets` (atomic). Called after a push updates statuses in
/// memory so a back-to-back push (e.g. two editor saves) sees no delta and is a no-op. Best
/// effort: a write failure only means the next push may re-PATCH an already-correct status.
fn write_cache(path: &Path, tickets: &[Ticket]) {
    let mut s = String::new();
    for t in tickets {
        s.push_str(&format!(
            "{}\t{}\t{}\t{}\n",
            t.id, t.priority, t.status, t.title
        ));
    }
    let _ = md::write_atomic(path, &s);
}

/// Refresh the cache by running `notes-clickup-fetch --list <id> --out <cache>`. Best-effort:
/// a spawn failure (helper not on PATH) or a non-zero exit (no token, network down) is warned
/// and swallowed — the reconcile then proceeds against the last-known cache, so a manual
/// `notes clickup sync` degrades to "show me what ClickUp last said" rather than erroring.
/// The helper self-bounds its HTTP with `curl --max-time`, so there is no timer to manage here.
fn refresh_cache(list: &str, cache: &std::path::Path, log: &Logger) {
    match Command::new(FETCH_BIN)
        .arg("--list")
        .arg(list)
        .arg("--out")
        .arg(cache)
        .output()
    {
        Ok(o) if o.status.success() => log.info("clickup", "refreshed the ClickUp cache"),
        Ok(o) => log.warn(
            "clickup",
            &format!(
                "{FETCH_BIN} exited {}: {} (using last-known cache)",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            ),
        ),
        Err(e) => log.warn(
            "clickup",
            &format!("{FETCH_BIN} not run ({e}); using last-known cache"),
        ),
    }
}

/// The ClickUp status a Focus line's checkbox implies, or `None` for a line that should not be
/// pushed. `[x]` -> done, `[/]` -> in progress. A plain `[ ]` is deliberately NOT pushed: it is
/// ambiguous (it is also what the overnight carry leaves after resetting an in-progress mark).
fn implied_status(line: &str) -> Option<&'static str> {
    if md::is_checked(line) {
        Some(DONE_STATUS)
    } else if line.trim_start().starts_with("- [/]") {
        Some(IN_PROGRESS_STATUS)
    } else {
        None
    }
}

/// Pure planning core of the write-back: which cache tickets need a status PATCH given the
/// note's `## Focus` checkboxes. For each authored, cu-linked task line whose implied status
/// differs from the cache baseline, emit `(ticket_index, target_status)`. Testable without
/// touching ClickUp. Identity is two-tier like the pull: the `<!-- cu:ID -->` marker first
/// (same-day), then `md::task_key` from the title (recovers the id after the marker is dropped
/// on the overnight carry). One push per ticket even if two lines map to it.
fn plan_pushes(content: &str, tickets: &[Ticket]) -> Vec<(usize, &'static str)> {
    let by_id: HashMap<&str, usize> = tickets
        .iter()
        .enumerate()
        .map(|(i, t)| (t.id.as_str(), i))
        .collect();
    let mut by_key: HashMap<String, usize> = HashMap::new();
    for (i, t) in tickets.iter().enumerate() {
        by_key
            .entry(md::task_key(&format!("- [ ] {}", t.title)))
            .or_insert(i);
    }
    let mut plans: Vec<(usize, &'static str)> = Vec::new();
    let mut seen: HashSet<usize> = HashSet::new();
    for line in md::section_lines(content, FOCUS)
        .unwrap_or_default()
        .iter()
        .filter(|l| md::is_task(l))
    {
        let Some(implied) = implied_status(line) else {
            continue;
        };
        let idx = md::cu_marker(line)
            .and_then(|id| by_id.get(id.as_str()).copied())
            .or_else(|| by_key.get(&md::task_key(line)).copied());
        let Some(idx) = idx else {
            continue; // not a mirrored ticket (or its ticket left the in-progress cache)
        };
        if !seen.insert(idx) {
            continue; // already planned this ticket from an earlier line
        }
        if tickets[idx].status.eq_ignore_ascii_case(implied) {
            continue; // no delta — ClickUp already has this status
        }
        plans.push((idx, implied));
    }
    plans
}

/// PATCH one ticket's status through the fetch helper (`--patch-status <id> <status>`), keeping
/// all HTTP in that script. Best-effort: a failure warns and returns false so the caller leaves
/// the cache baseline unchanged (the delta stays live and the next push retries).
fn patch_status(id: &str, status: &str, log: &Logger) -> bool {
    match Command::new(FETCH_BIN)
        .arg("--patch-status")
        .arg(id)
        .arg(status)
        .output()
    {
        Ok(o) if o.status.success() => true,
        Ok(o) => {
            log.warn(
                "clickup",
                &format!(
                    "patch {id} -> '{status}' failed ({}): {}",
                    o.status,
                    String::from_utf8_lossy(&o.stderr).trim()
                ),
            );
            false
        }
        Err(e) => {
            log.warn("clickup", &format!("patch {id} not run ({e})"));
            false
        }
    }
}

/// Apply planned pushes: PATCH each in ClickUp and, on success, advance the in-memory cache
/// baseline so a repeat push is a no-op. Returns the count actually pushed.
fn apply_pushes(tickets: &mut [Ticket], plans: &[(usize, &'static str)], log: &Logger) -> usize {
    let mut n = 0;
    for &(idx, status) in plans {
        if patch_status(&tickets[idx].id, status, log) {
            tickets[idx].status = status.to_string();
            n += 1;
        }
    }
    n
}

/// Build the Focus line for a new ticket: a stamped, in-progress (`[/]`) task carrying its
/// priority tag and the `<!-- cu:ID -->` marker last. `stamp_line` resets `[/]`→`[ ]`, so the
/// checkbox is set to in-progress AFTER stamping; the marker rides at the very end where
/// `task_key` truncates it away (dedup stays title-based) and the priority still parses.
fn new_focus_line(t: &Ticket, today: chrono::NaiveDate) -> String {
    let tag = priority_tag(&t.priority);
    let base = if tag.is_empty() {
        format!("- [ ] {}", t.title)
    } else {
        format!("- [ ] {} {}", t.title, tag)
    };
    let stamped = md::stamp_line(&base, today, today);
    let in_progress = md::set_checkbox(&stamped, '/');
    format!("{in_progress} <!-- cu:{} -->", t.id)
}

/// `notes clickup sync` — pull in-progress ClickUp tickets into today's `## Focus`.
pub fn sync(p: &Profile, log: &Logger) -> Result<i32> {
    let Some(list) = p.clickup_list.as_deref() else {
        // Opt-in like `## Watches`: a profile without a list id has no ClickUp bridge. Say so
        // (this is a hand-run command) rather than silently doing nothing.
        println!(
            "clickup bridge not configured for profile '{}' (set `clickup_list` in the notes config)",
            p.name
        );
        return Ok(0);
    };

    let cache = p.state_dir.join("clickup-inprogress.tsv");
    // Always try for fresh data on a manual run; fall back to the cache on any failure.
    refresh_cache(list, &cache, log);
    let mut tickets = parse_cache(&fs::read_to_string(&cache).unwrap_or_default());

    // Bootstrap today's note (+ `## Focus`) exactly like `focus add`, and refuse to append
    // when the heading is absent — a section appended below the backlog footer would be
    // truncated by tomorrow's carry.
    let note = daily::today_path(p);
    if !note.exists() {
        daily::run(p, log)?;
    }
    let content = fs::read_to_string(&note)?;
    if md::section_lines(&content, FOCUS).is_none() {
        bail!(
            "no `## Focus` section in {} — run `notes today` first",
            note.display()
        );
    }

    // PUSH first: reflect the user's status edits ([/]/[x] on cu-linked lines) up to ClickUp
    // against the freshly-fetched baseline, then PULL new in-progress tickets down. Push only
    // writes to ClickUp + the cache, never the note, so `content` is still valid for the pull.
    let plans = plan_pushes(&content, &tickets);
    let pushed = apply_pushes(&mut tickets, &plans, log);
    if pushed > 0 {
        write_cache(&cache, &tickets);
    }

    // What's already in the authored Focus region: cu-ids (same-day marker) + normalised keys
    // (survive the carry). Either match means "already mirrored" — leave it untouched.
    let existing = md::section_lines(&content, FOCUS).unwrap_or_default();
    let mut have_cu: HashSet<String> = existing.iter().filter_map(|l| md::cu_marker(l)).collect();
    let mut have_key: HashSet<String> = existing
        .iter()
        .filter(|l| md::is_task(l))
        .map(|l| md::task_key(l))
        .collect();

    let today = Local::now().date_naive();
    let mut new_lines: Vec<String> = Vec::new();
    for t in &tickets {
        let key = md::task_key(&format!("- [ ] {}", t.title));
        if have_cu.contains(&t.id) || have_key.contains(&key) {
            continue; // already on the board (or the user's own task of the same name)
        }
        new_lines.push(new_focus_line(t, today));
        have_cu.insert(t.id.clone());
        have_key.insert(key);
    }

    if !new_lines.is_empty() {
        let updated = md::insert_under_heading(&content, FOCUS, &new_lines);
        md::write_atomic(&note, &updated)?;
        // Land the new items in their priority lanes, same as a cockpit/editor edit would.
        focus_sweep::sweep(p, log)?;
        log.info(
            "clickup",
            &format!(
                "added {} in-progress ticket(s) to ## Focus",
                new_lines.len()
            ),
        );
    }
    println!(
        "clickup sync: {} in-progress ticket(s), {pushed} pushed, {} new in Focus",
        tickets.len(),
        new_lines.len()
    );
    Ok(0)
}

/// `notes clickup push` — push the user's status edits on cu-linked `## Focus` items up to
/// ClickUp, WITHOUT a network fetch (fast; this is the on-save trigger). Delta is computed
/// against the existing cache, so a `[x]` on a mirrored line closes its ticket and a repeat
/// push is a no-op. No-op when the bridge is unconfigured, the cache is absent, or the note
/// does not exist yet (push is reactive — it never bootstraps the note).
pub fn push(p: &Profile, log: &Logger) -> Result<i32> {
    if p.clickup_list.is_none() {
        println!(
            "clickup bridge not configured for profile '{}' (set `clickup_list` in the notes config)",
            p.name
        );
        return Ok(0);
    }
    let cache = p.state_dir.join("clickup-inprogress.tsv");
    let mut tickets = parse_cache(&fs::read_to_string(&cache).unwrap_or_default());

    let note = daily::today_path(p);
    let Ok(content) = fs::read_to_string(&note) else {
        // No note yet -> nothing to push. Silent-ish: push runs from editor save, so keep quiet.
        return Ok(0);
    };

    let plans = plan_pushes(&content, &tickets);
    let pushed = apply_pushes(&mut tickets, &plans, log);
    if pushed > 0 {
        write_cache(&cache, &tickets);
        log.info("clickup", &format!("pushed {pushed} status update(s)"));
    }
    println!("clickup push: {pushed} status update(s)");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> chrono::NaiveDate {
        chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn parse_cache_reads_4col_and_legacy_3col() {
        // 4-col (Phase 2) mixed with a legacy 3-col row; blank/comment/malformed dropped.
        let tsv = "# header\n\nabc\thigh\tin progress\tWire pin-code flow\nleg\tlow\tLegacy 3-col\nnoTitle\tlow\tin progress\t\n\tlow\tin progress\tno id\n";
        let t = parse_cache(tsv);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].id, "abc");
        assert_eq!(t[0].priority, "high");
        assert_eq!(t[0].status, "in progress");
        assert_eq!(t[0].title, "Wire pin-code flow");
        // Legacy 3-col: status defaults empty, title is the 3rd column.
        assert_eq!(t[1].id, "leg");
        assert_eq!(t[1].priority, "low");
        assert_eq!(t[1].status, "");
        assert_eq!(t[1].title, "Legacy 3-col");
    }

    #[test]
    fn implied_status_maps_checkbox() {
        assert_eq!(implied_status("- [x] done it"), Some("completed"));
        assert_eq!(implied_status("  - [X] done it"), Some("completed"));
        assert_eq!(implied_status("- [/] doing it"), Some("in progress"));
        // A plain open todo is NOT pushed (ambiguous with the overnight carry reset).
        assert_eq!(implied_status("- [ ] just a todo"), None);
        assert_eq!(implied_status("- [ ]"), None);
        assert_eq!(implied_status("prose"), None);
    }

    fn tk(id: &str, status: &str, title: &str) -> Ticket {
        Ticket {
            id: id.into(),
            priority: "".into(),
            status: status.into(),
            title: title.into(),
        }
    }

    #[test]
    fn plan_pushes_only_on_delta_and_resolves_id_two_ways() {
        let tickets = vec![
            tk("abc", "in progress", "Wire pin-code flow"),
            tk("def", "in progress", "Reboot pause"),
            tk("ghi", "in progress", "Update slides"),
        ];
        // - abc: done via cu-marker -> completed (delta)
        // - def: carried, markerless [x], id recovered by title_key -> completed (delta)
        // - ghi: [/] but cache already "in progress" -> no delta, skipped
        // - a non-mirrored user task -> skipped
        let content = "## Focus\n\
            - [x] Wire pin-code flow (0d) <!-- since:2026-07-22 --> <!-- cu:abc -->\n\
            - [x] Reboot pause (1d) <!-- since:2026-07-22 -->\n\
            - [/] Update slides (0d) <!-- since:2026-07-22 --> <!-- cu:ghi -->\n\
            - [x] my own thing\n\
            \n## Notes\n";
        let plans = plan_pushes(content, &tickets);
        assert_eq!(plans.len(), 2);
        assert!(plans.contains(&(0, "completed"))); // abc by marker
        assert!(plans.contains(&(1, "completed"))); // def by title_key
        assert!(!plans.iter().any(|(i, _)| *i == 2)); // ghi: no delta
    }

    #[test]
    fn plan_pushes_stops_at_rollup_sentinel() {
        let tickets = vec![
            tk("mine", "in progress", "mine"),
            tk("theirs", "in progress", "theirs"),
        ];
        let content = format!(
            "## Focus\n- [x] mine <!-- cu:mine -->\n\n{}\n- [x] theirs <!-- cu:theirs -->\n\n## Notes\n",
            md::ROLLUP_START
        );
        let plans = plan_pushes(&content, &tickets);
        // Only the authored (pre-sentinel) line is considered; the mirrored one past it is not.
        assert_eq!(plans, vec![(0, "completed")]);
    }

    #[test]
    fn priority_tag_maps_clickup_words() {
        assert_eq!(priority_tag("urgent"), "#urgent");
        assert_eq!(priority_tag("High"), "#high");
        assert_eq!(priority_tag("normal"), ""); // "normal" has no lane in the 3-level model
        assert_eq!(priority_tag("low"), "#low");
        assert_eq!(priority_tag(""), "");
        assert_eq!(priority_tag("bogus"), "");
    }

    #[test]
    fn new_focus_line_is_in_progress_stamped_tagged_and_marked() {
        let t = Ticket {
            id: "abc123".into(),
            priority: "high".into(),
            status: "in progress".into(),
            title: "Wire pin-code flow".into(),
        };
        let line = new_focus_line(&t, d("2026-07-22"));
        assert_eq!(
            line,
            "- [/] Wire pin-code flow (0d) <!-- since:2026-07-22 --> #high <!-- cu:abc123 -->"
        );
        // The marker is recoverable, and the dedup key ignores both marker and priority, so a
        // re-sync (or a carried, markerless copy derived from the same title) dedupes cleanly.
        assert_eq!(md::cu_marker(&line).as_deref(), Some("abc123"));
        assert_eq!(md::task_key(&line), "wire pin-code flow");
        assert_eq!(
            md::task_key(&line),
            md::task_key("- [ ] Wire pin-code flow")
        );
        // The priority still parses for the lane sweep despite the trailing marker.
        assert_eq!(md::task_priority(&line), Some("#high"));
    }

    #[test]
    fn new_focus_line_without_priority_has_no_tag() {
        let t = Ticket {
            id: "z9".into(),
            priority: "".into(),
            status: "in progress".into(),
            title: "loose task".into(),
        };
        let line = new_focus_line(&t, d("2026-07-22"));
        assert_eq!(
            line,
            "- [/] loose task (0d) <!-- since:2026-07-22 --> <!-- cu:z9 -->"
        );
        assert_eq!(md::task_priority(&line), None);
    }
}
