//! `hub-cases ingest`: reads every finished run of a repo's declared test workflow into the
//! per-case ledger (`hub_core::cases`), once. `schedules-sync`'s timer runs it after its own sync.
//!
//! ```text
//! hub-cases ingest [--repo OWNER/NAME] [--days N] [--cap N] [--budget-secs N]
//!                  [--backfill [--bundle GLOB]...]
//! ```
//!
//! A bare `ingest` reads the last `LIVE_DAYS` of runs, at most `PASS_FETCHES` fetched, newest
//! first. `--backfill` reads main's nightly and same-SHA proof runs over `--days` (30 by default),
//! and with `--bundle 'test-runs-*'` falls back to the old bundles for runs from before
//! `meta.json`. Exit 0 when the pass finished or stopped at a bound it names (the cap, the time,
//! the GitHub budget reserve); exit 1 when a fetch or a write failed, so the unit shows it.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use hub_core::builds;
use hub_core::cases::{self, Opts};
use hub_core::junit;
use hub_core::session_actions::System;

/// The wall time a pass keeps to when no `--budget-secs` is given: under the unit's 600 s start
/// timeout, which `schedules-sync` has used some of.
const BUDGET_SECS: u64 = 240;

const USAGE: &str = "usage: hub-cases ingest [--repo OWNER/NAME] [--days N] [--cap N] [--budget-secs N] [--backfill [--bundle GLOB]...]";

fn parse(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts::default();
    let mut days = None;
    let mut secs = BUDGET_SECS;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = |what: &str| it.next().cloned().ok_or(format!("{a} needs {what}"));
        match a.as_str() {
            "--repo" => o.repo = Some(val("OWNER/NAME")?),
            "--days" => {
                days = Some(
                    val("a count")?
                        .parse::<i64>()
                        .map_err(|e| format!("--days: {e}"))?,
                )
            }
            "--cap" => o.cap = val("a count")?.parse().map_err(|e| format!("--cap: {e}"))?,
            "--budget-secs" => {
                secs = val("a count")?
                    .parse()
                    .map_err(|e| format!("--budget-secs: {e}"))?
            }
            "--bundle" => o.bundle.push(val("a glob")?),
            "--backfill" => o.backfill = true,
            _ => return Err(format!("unknown argument {a}")),
        }
    }
    o.days = days.unwrap_or(if o.backfill {
        cases::BACKFILL_DAYS
    } else {
        cases::LIVE_DAYS
    });
    if !o.bundle.is_empty() && !o.backfill {
        return Err("--bundle is for --backfill".into());
    }
    o.until = Some(Instant::now() + Duration::from_secs(secs));
    Ok(o)
}

/// A scratch place for downloads: a run's artifacts are read once and removed, never kept beside
/// the hub's own cache (a bundle is 89 MB).
fn scratch() -> PathBuf {
    let base = agent_core::vocab::env_path("XDG_CACHE_HOME")
        .or_else(|| agent_core::vocab::env_path("HOME").map(|h| h.join(".cache")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("hub-cases").join(std::process::id().to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some("ingest"), rest) = (
        args.first().map(String::as_str),
        args.get(1..).unwrap_or(&[]),
    ) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let opts = match parse(rest) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("hub-cases: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let now = hub_core::jobs::now();
    let registry = project_map::Registry::load();
    let ledger = builds::read(&builds::Paths::from_env(), None, now);
    let runs = junit::all_finished(&ledger, registry.as_ref());
    let cache = scratch();
    let report = cases::ingest(&cases::root(), runs, &opts, now, &mut |run| {
        // the run before this one is read: its download goes
        let _ = std::fs::remove_dir_all(&cache);
        junit::fetched(&cache, run, &System)
    });
    let _ = std::fs::remove_dir_all(&cache);
    println!("{}", report.says());
    for line in report.infra.iter().chain(&report.refused) {
        println!("  {line}");
    }
    for e in &report.errors {
        eprintln!("hub-cases: {e}");
    }
    if report.errors.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
