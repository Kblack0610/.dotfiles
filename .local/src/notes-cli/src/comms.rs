//! `notes comms`: surface multi-account email triage onto the comms status page.
//!
//! Division of labour (mirrors the Sentinel watches model):
//!   - The **triage poller** (`comms-fetch.py` + `comms-triage.sh`, driven by
//!     `agentctl@comms`) does all the network + LLM work: it pulls each mailbox, applies
//!     Gmail labels, and writes a *pre-rendered* per-profile surface file at
//!     `<state_dir>/surface/<profile>.md` (one `- …` bullet per critical/action item).
//!   - This module (and `notes today`) is **read-only + offline**: it just reads that
//!     surface file and renders it as `status/comms.md`, exactly like `refresh_watches`
//!     reads `<name>.state` files. No network, no LLM, no new crate deps.
//!
//! So `notes today` stays fast and works with no connectivity; the freshness of the page is
//! whatever the poller last wrote. It is a page and not a note section because mail moves all
//! day, and the daily note is only written when it is created.

use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::status;
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
/// when comms is unconfigured / the snapshot is absent. Rendered as the comms page's lead line.
pub fn summary_line() -> Option<String> {
    let c = config::comms_config().ok()?;
    if c.accounts.is_empty() {
        return None;
    }
    let s = fs::read_to_string(config::comms_stats_summary_file(&c)).ok()?;
    let line = s.lines().next()?.trim();
    (!line.is_empty()).then(|| line.to_string())
}

/// The comms status page from the poller's summary line and surface bullets. Pure, so the
/// tiering is testable without a configured mailbox. Every surfaced line is a critical or
/// action item, so all of them need attention; CRITICAL sorts above ACTION, and the poller's
/// own order is kept within a tier.
pub(crate) fn comms_page(summary: Option<&str>, lines: &[String]) -> status::Page {
    let rows = lines
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let head = l.trim_start().trim_start_matches("- ").to_string();
            let tier = match head.split_whitespace().next() {
                Some("CRITICAL") => 0,
                Some("ACTION") => 1,
                _ => 2,
            };
            status::Row {
                attention: true,
                sort: (tier, format!("{i:04}")),
                head,
                detail: vec![],
            }
        })
        .collect();
    status::Page {
        feed: status::Feed::Comms,
        stat: summary.map(str::to_string),
        rows,
    }
}

/// Publish the comms page from the triage poller's surface file and take any `## Comms`
/// section out of the note. Runs every `notes today` so the page tracks the poller.
///
/// Skipped when comms is unconfigured on this machine, which is the guard against sync
/// ping-pong: a machine without comms config must not strip a `## Comms` section another
/// machine wrote, nor overwrite the page it publishes.
pub fn refresh(p: &Profile, log: &Logger, note: &Path) -> Result<()> {
    let present = config::comms_config().is_ok_and(|c| !c.accounts.is_empty());
    let page = comms_page(summary_line().as_deref(), &surface_lines(&p.name));
    daily::publish_and_strip(p, log, note, &page, present, "Comms")
}

/// `notes comms` (default / `list`): print the currently-surfaced comms lines for the
/// active profile. Read-only; the same lines the comms page renders.
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

/// `notes comms refresh`: ensure today's note exists, then re-publish the comms page from
/// the surface file. A manual trigger for the same work `notes today` does.
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

    fn line(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn every_surfaced_line_needs_attention_and_critical_leads() {
        let lines = vec![
            line("- ACTION [personal] renew passport"),
            line("- CRITICAL [work] Re: contract - alice@acme"),
        ];
        let page = comms_page(Some("Inbox 9k - 1 crit"), &lines);
        assert_eq!(page.feed, status::Feed::Comms);
        assert_eq!(page.stat.as_deref(), Some("Inbox 9k - 1 crit"));
        assert!(page.rows.iter().all(|r| r.attention));
        let mut rows: Vec<_> = page.rows.iter().collect();
        rows.sort_by(|a, b| a.sort.cmp(&b.sort));
        assert_eq!(rows[0].head, "CRITICAL [work] Re: contract - alice@acme");
        assert_eq!(rows[1].head, "ACTION [personal] renew passport");
    }

    #[test]
    fn nothing_surfaced_is_an_empty_page() {
        let page = comms_page(None, &[]);
        assert!(page.rows.is_empty() && page.stat.is_none());
    }
}
