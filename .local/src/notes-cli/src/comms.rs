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
use anyhow::Result;
use std::fs;
use std::path::Path;

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

/// Build the `## Comms` section into `existing`, replacing any prior one in place. Pure
/// (no I/O) so it is unit-testable and provably idempotent: a second pass over its own
/// output is byte-stable. Empty `lines` strips the section entirely.
pub(crate) fn render_comms(existing: &str, lines: &[String]) -> String {
    let stripped = daily::remove_section(existing, "Comms");
    if lines.is_empty() {
        return stripped;
    }
    let mut block = String::from("\n\n## Comms\n");
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
    let new_content = render_comms(&content, &lines);
    if new_content != content {
        fs::write(note, &new_content)?;
        log.info("today", &format!("refreshed ## Comms ({} item(s))", lines.len()));
    }
    Ok(())
}

/// `notes comms` (default / `list`): print the currently-surfaced comms lines for the
/// active profile. Read-only; the same lines `## Comms` would render.
pub fn list(p: &Profile, _log: &Logger) -> Result<()> {
    let lines = surface_lines(&p.name);
    if lines.is_empty() {
        println!("(no surfaced comms for profile '{}')", p.name);
    } else {
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
pub fn status(_p: &Logger) -> Result<()> {
    let c = config::comms_config()?;
    if c.accounts.is_empty() {
        println!("comms: not configured (no [[comms.account]] entries)");
        return Ok(());
    }
    println!("comms state: {}", c.state_dir.display());
    println!("ollama:      {} ({})", c.ollama_url, c.ollama_model);
    for a in &c.accounts {
        let surface = config::comms_surface_file(&c, &a.surface_profile);
        let has = if surface.exists() { "surfaced" } else { "no surface file" };
        println!(
            "  {} -> {} (rbw: {}) [{}]",
            a.name, a.surface_profile, a.rbw_entry, has
        );
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
        let out = render_comms(BASE, &lines);
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
        let once = render_comms(BASE, &lines);
        let twice = render_comms(&once, &lines);
        assert_eq!(once, twice, "re-rendering its own output must be byte-stable");
    }

    #[test]
    fn empty_lines_strip_section() {
        let lines = vec!["- CRITICAL [work] x".to_string()];
        let with = render_comms(BASE, &lines);
        assert!(with.contains("## Comms"));
        let without = render_comms(&with, &[]);
        assert!(!without.contains("## Comms"));
        // Stripping restores the original (footer + focus intact).
        assert_eq!(without, BASE);
    }
}
