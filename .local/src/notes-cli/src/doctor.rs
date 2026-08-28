//! `notes doctor` — the "figure out exactly why issues happen" tool. It surfaces
//! the failure modes the old silent scripts hid: summarize gaps, malformed
//! headings, stale sync, dead links. Exit code is non-zero only on hard FAILs
//! (broken config / missing vault root); WARNs are informational.

use crate::config::Profile;
use crate::index;
use crate::projects;
use crate::logging::Logger;
use anyhow::Result;
use chrono::{Duration, Local, NaiveDate};
use std::fs;
use std::path::Path;

enum Status {
    Pass,
    Warn,
    Fail,
}

struct Report {
    fails: u32,
    warns: u32,
}

impl Report {
    fn new() -> Self {
        Report { fails: 0, warns: 0 }
    }
    fn add(&mut self, status: Status, label: &str, detail: &str) {
        let mark = match status {
            Status::Pass => "✓",
            Status::Warn => {
                self.warns += 1;
                "⚠"
            }
            Status::Fail => {
                self.fails += 1;
                "✗"
            }
        };
        if detail.is_empty() {
            println!("{mark} {label}");
        } else {
            println!("{mark} {label}: {detail}");
        }
    }
}

pub fn run(p: &Profile, log: &Logger) -> Result<i32> {
    let mut r = Report::new();
    println!("notes doctor — profile '{}' ({})\n", p.name, p.source);

    // 1. Vault root + key directories
    if p.root.is_dir() {
        r.add(Status::Pass, "root", &p.root.display().to_string());
    } else {
        r.add(
            Status::Fail,
            "root",
            &format!("missing {}", p.root.display()),
        );
    }
    dir_check(&mut r, "daily", &p.daily, false);
    dir_check(&mut r, "refs", &p.refs, true);
    dir_check(&mut r, "continuous", &p.continuous, true);
    file_check(&mut r, "fun backlog", &p.fun);
    // The schedule, not its pre-merge `scheduled.md` ancestor: that file was folded into
    // `schedule.md` and renamed aside, so checking it reported a healthy vault as broken.
    file_check(&mut r, "schedule", &p.schedule);

    // Inbox backlog — pending captures awaiting triage; warn if any are stale
    let (pending, stale) = crate::inbox::backlog_counts(p);
    if stale > 0 {
        r.add(
            Status::Warn,
            "inbox backlog",
            &format!("{pending} pending, {stale} stale (≥14d) — `notes inbox`"),
        );
    } else {
        r.add(Status::Pass, "inbox backlog", &format!("{pending} pending"));
    }

    // 2. Summarize gaps — daily notes older than yesterday with no continuous entry
    check_gaps(&mut r, p);

    // 3. Heading validity on current daily notes
    check_headings(&mut r, p);

    // 4. Sync freshness (sync layer is owned elsewhere; we only observe)
    check_sync(&mut r);

    // 5. Service status (Linux/systemd; skipped elsewhere)
    check_services(&mut r);

    // 6. Zettelkasten: dead links + orphans
    match index::scan(p) {
        Ok(s) => {
            if s.dead.is_empty() {
                r.add(Status::Pass, "dead links", "none");
            } else {
                let sample: Vec<String> = s
                    .dead
                    .iter()
                    .take(5)
                    .map(|(a, b)| format!("{a}→{b}"))
                    .collect();
                r.add(
                    Status::Warn,
                    "dead links",
                    &format!("{} ({})", s.dead.len(), sample.join(", ")),
                );
            }
            if !s.notes.is_empty() && !s.orphans.is_empty() {
                r.add(
                    Status::Warn,
                    "orphan notes",
                    &format!("{} with no backlinks", s.orphans.len()),
                );
            }
        }
        Err(e) => r.add(Status::Warn, "zettel scan", &e.to_string()),
    }

    // 7. Version pairing: a frozen version and its ai/ evidence note travel together
    let pairing = projects::pairing_findings(p);
    if pairing.is_empty() {
        r.add(Status::Pass, "version pairing", "every frozen version matches its agent note");
    } else {
        r.add(
            Status::Warn,
            "version pairing",
            &format!("{} unpaired ({})", pairing.len(), pairing.join("; ")),
        );
    }

    // 8. Wave order: the first `## Wave` names the sheet's declared `Version:`. Every reader
    // takes the first section as the current wave, so a roadmap that opens with a planned one
    // silently redirects the board, `ptask list` and `/wave` onto unstarted work.
    let order = projects::wave_order_findings(p);
    if order.is_empty() {
        r.add(Status::Pass, "wave order", "every sheet opens with its declared version");
    } else {
        r.add(
            Status::Warn,
            "wave order",
            &format!("{} out of order ({})", order.len(), order.join("; ")),
        );
    }

    // 9. A binary older than its own source silently writes the previous note format, and
    // nothing else here would catch it: every path resolves, every heading parses, the notes
    // are simply the wrong shape. That is exactly how one machine's dailies drifted a month
    // behind another's while both looked healthy.
    check_build(&mut r);

    println!();
    let code = if r.fails > 0 { 1 } else { 0 };
    let summary = format!("{} fail, {} warn", r.fails, r.warns);
    println!("{summary}");
    if r.fails > 0 {
        log.warn("doctor", &summary);
    } else {
        log.info("doctor", &summary);
    }
    Ok(code)
}

/// Compare the running executable against the newest file in the source tree it was compiled
/// from. `CARGO_MANIFEST_DIR` is baked in at build time, so this needs no config and no build
/// script; a checkout that has since moved or been deleted cannot be compared and passes.
fn check_build(r: &mut Report) {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(built) = mtime(&exe) else {
        return;
    };
    if !src.is_dir() {
        r.add(Status::Pass, "build", "source tree not present, cannot compare");
        return;
    }
    let newest = fs::read_dir(&src)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "rs"))
        .filter_map(|p| mtime(&p).map(|t| (t, p)))
        .max();
    match newest {
        Some((t, p)) if t > built => r.add(
            Status::Warn,
            "build",
            &format!(
                "binary is stale ({} is newer) - run `cargo build --release` in {}",
                p.file_name().unwrap_or_default().to_string_lossy(),
                src.parent().unwrap_or(&src).display()
            ),
        ),
        _ => r.add(Status::Pass, "build", "binary is current with its source"),
    }
}

fn mtime(path: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(path).ok()?.modified().ok()
}

fn dir_check(r: &mut Report, label: &str, path: &Path, warn_only: bool) {
    if path.is_dir() {
        r.add(Status::Pass, label, &path.display().to_string());
    } else {
        let status = if warn_only {
            Status::Warn
        } else {
            Status::Fail
        };
        r.add(status, label, &format!("missing {}", path.display()));
    }
}

fn file_check(r: &mut Report, label: &str, path: &Path) {
    if path.is_file() {
        r.add(Status::Pass, label, "");
    } else {
        r.add(
            Status::Warn,
            label,
            &format!("missing {} (run `notes today`)", path.display()),
        );
    }
}

/// A "gap" is a daily note for a date strictly before yesterday that has no
/// `### date` entry in its month's continuous log. This is the class of bug that
/// produced "last month didn't summarize correctly".
fn check_gaps(r: &mut Report, p: &Profile) {
    if !p.daily.is_dir() {
        return;
    }
    let cutoff = Local::now().date_naive() - Duration::days(1);
    let mut gaps: Vec<String> = Vec::new();

    let entries = match fs::read_dir(&p.daily) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let stem = match path.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        let date = match NaiveDate::parse_from_str(&stem, "%Y-%m-%d") {
            Ok(d) => d,
            Err(_) => continue,
        };
        if date >= cutoff {
            continue; // today / yesterday aren't expected to be summarized yet
        }
        let month = &stem[..7];
        let log_path = p.continuous.join(format!("{month}.md"));
        let logged = fs::read_to_string(&log_path)
            .map(|c| c.contains(&format!("### {stem}")))
            .unwrap_or(false);
        if !logged {
            gaps.push(stem);
        }
    }
    gaps.sort();

    if gaps.is_empty() {
        r.add(Status::Pass, "summarize gaps", "none");
    } else {
        let sample: Vec<String> = gaps.iter().take(8).cloned().collect();
        r.add(
            Status::Warn,
            "summarize gaps",
            &format!(
                "{} un-summarized day(s): {}{}",
                gaps.len(),
                sample.join(", "),
                if gaps.len() > sample.len() {
                    " …"
                } else {
                    ""
                }
            ),
        );
    }
}

fn check_headings(r: &mut Report, p: &Profile) {
    if !p.daily.is_dir() {
        return;
    }
    let mut bad: Vec<String> = Vec::new();
    if let Ok(entries) = fs::read_dir(&p.daily) {
        for entry in entries.flatten() {
            let path = entry.path();
            let stem = match path.file_stem().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if NaiveDate::parse_from_str(&stem, "%Y-%m-%d").is_err() {
                continue;
            }
            let content = fs::read_to_string(&path).unwrap_or_default();
            // `## Focus` is the whole contract. Requiring `## Due` too outlived the section
            // itself: the engine stopped writing it (one list, not two), so demanding it
            // failed every correctly-generated note and passed the stale ones.
            if !content.contains("## Focus") {
                bad.push(stem);
            }
        }
    }
    if bad.is_empty() {
        r.add(Status::Pass, "daily headings", "every note has Focus");
    } else {
        bad.sort();
        r.add(
            Status::Warn,
            "daily headings",
            &format!(
                "{} note(s) missing Focus: {}",
                bad.len(),
                bad.join(", ")
            ),
        );
    }
}

fn check_sync(r: &mut Report) {
    let home = std::env::var("HOME").unwrap_or_default();
    let log = Path::new(&home).join(".local/state/notes-sync/sync.log");
    if !log.exists() {
        r.add(
            Status::Warn,
            "sync log",
            "not found (sync may be unconfigured here)",
        );
        return;
    }
    match fs::metadata(&log).and_then(|m| m.modified()) {
        Ok(modified) => {
            let age = modified.elapsed().map(|d| d.as_secs()).unwrap_or(0);
            let hours = age / 3600;
            if hours <= 24 {
                r.add(Status::Pass, "sync log", &format!("updated {hours}h ago"));
            } else {
                r.add(
                    Status::Warn,
                    "sync log",
                    &format!("stale — last update {hours}h ago"),
                );
            }
        }
        Err(_) => r.add(Status::Warn, "sync log", "unreadable mtime"),
    }
}

fn check_services(r: &mut Report) {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let units = ["git-sync-notes.timer", "notes-watch.service"];
    for unit in units {
        let out = std::process::Command::new("systemctl")
            .args(["--user", "is-active", unit])
            .output();
        match out {
            Ok(o) => {
                let state = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if state == "active" {
                    r.add(Status::Pass, unit, "active");
                } else {
                    r.add(Status::Warn, unit, &state);
                }
            }
            Err(_) => {
                // systemctl absent — not a systemd machine; stay quiet
                return;
            }
        }
    }
}
