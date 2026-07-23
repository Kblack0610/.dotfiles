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
use std::collections::HashSet;
use std::fs;
use std::process::Command;

/// The section the bridge writes into (the daily cockpit's active-task lane).
const FOCUS: &str = "Focus";

/// The fetch helper, resolved on PATH (installed at `~/.dotfiles/.local/bin`). It owns the
/// ClickUp REST call + keychain token; this module never speaks HTTP, so the public notes
/// crate carries no ClickUp auth or network code (and no extra deps).
const FETCH_BIN: &str = "notes-clickup-fetch";

/// One in-progress ClickUp ticket, as read from the TSV cache.
struct Ticket {
    id: String,
    priority: String, // clickup priority word: urgent|high|normal|low|"" (none)
    title: String,
}

/// Map a ClickUp priority word to the note's priority hashtag; `""` (none) → no tag, so the
/// task sweeps into the untagged top bucket rather than a lane.
fn priority_tag(word: &str) -> &'static str {
    match word.trim().to_lowercase().as_str() {
        "urgent" => "#urgent",
        "high" => "#high",
        "normal" => "#medium",
        "low" => "#low",
        _ => "",
    }
}

/// Parse the TSV cache (`id<TAB>priority<TAB>title`, one ticket per line). Blank lines and
/// `#`-comment lines are skipped; a row missing the id or title is dropped rather than
/// injecting a malformed task. Tolerant by design — the cache is written by a separate tool.
fn parse_cache(text: &str) -> Vec<Ticket> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim_end_matches(['\r', '\n']);
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let mut cols = line.splitn(3, '\t');
        let id = cols.next().unwrap_or("").trim();
        let priority = cols.next().unwrap_or("").trim();
        let title = cols.next().unwrap_or("").trim();
        if id.is_empty() || title.is_empty() {
            continue;
        }
        out.push(Ticket {
            id: id.to_string(),
            priority: priority.to_string(),
            title: title.to_string(),
        });
    }
    out
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
    let tickets = parse_cache(&fs::read_to_string(&cache).unwrap_or_default());

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
        "clickup sync: {} in-progress ticket(s), {} new in Focus",
        tickets.len(),
        new_lines.len()
    );
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> chrono::NaiveDate {
        chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn parse_cache_skips_blank_comment_and_malformed_rows() {
        let tsv = "# header\n\nabc\thigh\tWire pin-code flow\ndef\t\tReboot pause\nnoTitle\tlow\t\n\tlow\tno id\n";
        let t = parse_cache(tsv);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].id, "abc");
        assert_eq!(t[0].priority, "high");
        assert_eq!(t[0].title, "Wire pin-code flow");
        // A row with an empty priority is fine (maps to no tag); id/title-empty rows are dropped.
        assert_eq!(t[1].id, "def");
        assert_eq!(t[1].priority, "");
    }

    #[test]
    fn priority_tag_maps_clickup_words() {
        assert_eq!(priority_tag("urgent"), "#urgent");
        assert_eq!(priority_tag("High"), "#high");
        assert_eq!(priority_tag("normal"), "#medium");
        assert_eq!(priority_tag("low"), "#low");
        assert_eq!(priority_tag(""), "");
        assert_eq!(priority_tag("bogus"), "");
    }

    #[test]
    fn new_focus_line_is_in_progress_stamped_tagged_and_marked() {
        let t = Ticket {
            id: "abc123".into(),
            priority: "high".into(),
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
