//! `notes comms` — surface multi-account email triage into the daily note.
//!
//! Division of labour (mirrors the Sentinel watches model):
//!   - The **triage poller** (`comms-fetch.py` + `comms-triage.sh`, driven by
//!     `agentctl@comms`) does all the network + LLM work: it pulls each mailbox, applies
//!     Gmail labels, and writes a *pre-rendered* per-profile surface file at
//!     `<state_dir>/surface/<profile>.md` (one `- …` bullet per critical/action item).
//!   - This module (and `notes today`) is **read-only + offline**: it just reads that
//!     surface file and renders it as a `## Comms` section, exactly like `refresh_watches`
//!     reads `<name>.state` files. No network, no LLM, no new crate deps.
//!
//! So `notes today` stays fast and works with no connectivity; the freshness of the
//! `## Comms` block is whatever the poller last wrote.

use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::Result;
use std::fs;
use std::path::Path;
use std::process::Command;

/// Rendered comms bullet lines for `profile`, from the poller's surface file. Empty when
/// comms is unconfigured, the surface file is absent, or it has no bullet lines. Read-only.
pub fn surface_lines(profile: &str) -> Vec<String> {
    let Ok(c) = config::comms_config() else {
        return Vec::new();
    };
    if c.accounts.is_empty() {
        return Vec::new();
    }
    let f = config::comms_surface_file(&c, profile);
    fs::read_to_string(&f)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.trim_start().starts_with("- "))
        .map(|l| l.to_string())
        .collect()
}

/// One-line cross-account stats summary (from the poller's `stats-summary.txt`), or None
/// when comms is unconfigured / the snapshot is absent. Rendered as the `## Comms` lead line.
pub fn summary_line() -> Option<String> {
    let c = config::comms_config().ok()?;
    if c.accounts.is_empty() {
        return None;
    }
    let s = fs::read_to_string(config::comms_stats_summary_file(&c)).ok()?;
    let line = s.lines().next()?.trim();
    (!line.is_empty()).then(|| line.to_string())
}

/// Build the `## Comms` section into `existing`, replacing any prior one in place. Pure
/// (no I/O) so it is unit-testable and provably idempotent: a second pass over its own
/// output is byte-stable. The section renders when EITHER a `summary` line or `lines`
/// exist; empty summary + empty lines strips the section entirely.
pub(crate) fn render_comms(existing: &str, summary: Option<&str>, lines: &[String]) -> String {
    let stripped = daily::remove_section(existing, "Comms");
    if summary.is_none() && lines.is_empty() {
        return stripped;
    }
    let mut block = String::from("\n\n## Comms\n");
    if let Some(s) = summary {
        block.push('_');
        block.push_str(s);
        block.push_str("_\n");
    }
    for l in lines {
        block.push_str(l);
        block.push('\n');
    }
    daily::insert_before_footer(&stripped, &block)
}

/// Refresh the daily note's `## Comms` section from the triage poller's surface file. Runs
/// every `notes today` (like `refresh_watches`) so it stays current as the poller writes.
///
/// No-op when comms is unconfigured on this machine (the surface file / config is absent),
/// which is the guard against sync ping-pong: a machine without comms config must not strip
/// a `## Comms` section another machine wrote and synced in.
pub fn refresh(p: &Profile, log: &Logger, note: &Path) -> Result<()> {
    // Feature off on this machine? Leave the note untouched (do NOT strip).
    match config::comms_config() {
        Ok(c) if !c.accounts.is_empty() => {}
        _ => return Ok(()),
    }
    let content = fs::read_to_string(note)?;
    let lines = surface_lines(&p.name);
    let summary = summary_line();
    let new_content = render_comms(&content, summary.as_deref(), &lines);
    if new_content != content {
        md::write_atomic(note, &new_content)?;
        log.info(
            "today",
            &format!("refreshed ## Comms ({} item(s))", lines.len()),
        );
    }
    Ok(())
}

/// `notes comms` (default / `list`): print the currently-surfaced comms lines for the
/// active profile. Read-only; the same lines `## Comms` would render.
pub fn list(p: &Profile, _log: &Logger) -> Result<()> {
    let summary = summary_line();
    let lines = surface_lines(&p.name);
    if summary.is_none() && lines.is_empty() {
        println!("(no surfaced comms for profile '{}')", p.name);
    } else {
        if let Some(s) = &summary {
            println!("{s}");
        }
        for l in &lines {
            println!("{l}");
        }
    }
    Ok(())
}

/// `notes comms refresh`: ensure today's note exists, then re-render its `## Comms`
/// section from the surface file. A manual trigger for the same work `notes today` does.
pub fn refresh_cmd(p: &Profile, log: &Logger) -> Result<()> {
    let note = daily::today_path(p);
    if !note.exists() {
        daily::run(p, log)?;
        return Ok(()); // daily::run already calls refresh() as part of its flow
    }
    refresh(p, log, &note)
}

/// `notes comms status`: show configured accounts and whether each surface file exists.
/// Read-only introspection — no network, no secrets touched (rbw item names only).
pub fn status(_log: &Logger) -> Result<()> {
    let c = config::comms_config()?;
    if c.accounts.is_empty() {
        println!("comms: not configured (no [[comms.account]] entries)");
        return Ok(());
    }
    println!("comms state: {}", c.state_dir.display());
    println!("llm:         {} ({})", c.llm_base_url, c.llm_model);
    for a in &c.accounts {
        let surface = config::comms_surface_file(&c, &a.surface_profile);
        let has = if surface.exists() {
            "surfaced"
        } else {
            "no surface file"
        };
        println!(
            "  {} -> {} (rbw: {}) [{}]",
            a.name, a.surface_profile, a.rbw_entry, has
        );
    }
    Ok(())
}

/// `notes comms stats [--fresh]`: cross-account email dashboard. Cached mode reads the
/// pre-rendered `stats.txt` the poller wrote (instant, offline, surface-file model);
/// `--fresh` runs the machine-local `comms-stats.py` (config `stats_bin`) for live IMAP.
pub fn stats(fresh: bool, _log: &Logger) -> Result<()> {
    let c = config::comms_config()?;
    if c.accounts.is_empty() {
        println!("comms: not configured (no [[comms.account]] entries)");
        return Ok(());
    }
    if fresh {
        match &c.stats_bin {
            Some(bin) if bin.exists() => {
                // Inherits stdout: comms-stats.py's default mode prints the live dashboard.
                Command::new(bin).status()?;
                return Ok(());
            }
            _ => {
                println!(
                    "comms: stats_bin not set/found (set comms.stats_bin -> comms-stats.py in \
                     config.toml for --fresh). Showing cached snapshot:\n"
                );
            }
        }
    }
    match fs::read_to_string(config::comms_stats_file(&c)) {
        Ok(s) => print!("{s}"),
        Err(_) => println!(
            "comms: no cached stats yet - run `notes comms stats --fresh` or wait for the poller"
        ),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "# 2026-07-18\n\n## Focus\n- [ ] a task\n\n---\nBacklogs: [[fun]]\n";

    #[test]
    fn render_inserts_above_footer() {
        let lines = vec!["- CRITICAL [work] Re: contract - alice@acme".to_string()];
        let out = render_comms(BASE, None, &lines);
        assert!(out.contains("## Comms\n- CRITICAL [work] Re: contract"));
        // Section sits above the backlog footer, not after it.
        let comms_at = out.find("## Comms").unwrap();
        let footer_at = out.find("\n---\nBacklogs:").unwrap();
        assert!(comms_at < footer_at);
    }

    #[test]
    fn render_is_idempotent() {
        let lines = vec![
            "- CRITICAL [work] Re: contract - alice@acme".to_string(),
            "- ACTION [personal] renew passport".to_string(),
        ];
        let once = render_comms(BASE, Some("Inbox 9k - 2 crit"), &lines);
        let twice = render_comms(&once, Some("Inbox 9k - 2 crit"), &lines);
        assert_eq!(
            once, twice,
            "re-rendering its own output must be byte-stable"
        );
    }

    #[test]
    fn summary_renders_as_italic_lead_line() {
        let out = render_comms(BASE, Some("Inbox 9k - 2 crit, 5 action"), &[]);
        // Section shows on summary alone (no bullets), summary italicized under the heading.
        assert!(out.contains("## Comms\n_Inbox 9k - 2 crit, 5 action_\n"));
    }

    #[test]
    fn empty_summary_and_lines_strip_section() {
        let lines = vec!["- CRITICAL [work] x".to_string()];
        let with = render_comms(BASE, Some("s"), &lines);
        assert!(with.contains("## Comms"));
        let without = render_comms(&with, None, &[]);
        assert!(!without.contains("## Comms"));
        // Stripping restores the original (footer + focus intact).
        assert_eq!(without, BASE);
    }
}
