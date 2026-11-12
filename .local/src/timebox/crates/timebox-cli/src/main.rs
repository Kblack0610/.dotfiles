//! `timebox` — start/stop named stopwatches (one per operation), get a recurring "switch
//! now" lap reminder for timeboxing, and track per-operation time. A one-shot CLI: it
//! mutates files under `~/.local/state/timebox/` and exits. Elapsed time is computed, so
//! nothing runs in the background; the Waybar poll (`timebox status --json`) both renders
//! the countdown and flushes any laps that have come due.

mod config;
mod logging;
mod notify;

use anyhow::{Context, Result};
use chrono::{DateTime, Local};
use clap::{Parser, Subcommand, ValueEnum};
use std::collections::BTreeMap;
use timebox_core::dur::{self, fmt_hms, fmt_short};
use timebox_core::state::{RunState, Snapshot};
use timebox_core::{stats, store, EventKind};

#[derive(Parser)]
#[command(
    name = "timebox",
    version,
    about = "Stopwatch + recurring-lap timeboxing tool"
)]
struct Cli {
    /// Echo log lines to stderr as well as the log file
    #[arg(short, long, global = true)]
    verbose: bool,

    /// Override "now" with an RFC3339 timestamp (testing/replay). Hidden.
    #[arg(long, global = true, hide = true)]
    now: Option<String>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Start (or resume) a stopwatch for an operation and make it active
    Start {
        /// Operation name, e.g. "deep-work"
        op: String,
        /// Recurring lap interval, e.g. 25m | 1h | 90s (defaults to config `default_lap`)
        #[arg(long)]
        lap: Option<String>,
        /// Play a sound when a lap boundary fires
        #[arg(long)]
        sound: bool,
    },
    /// Stop a stopwatch (banks its time). Defaults to the active one.
    Stop {
        op: Option<String>,
        /// Stop every stopwatch
        #[arg(long)]
        all: bool,
    },
    /// Pause the active (or named) stopwatch
    Pause { op: Option<String> },
    /// Resume the active (or named) stopwatch
    Resume { op: Option<String> },
    /// Manually close the current lap window and restart the cadence
    Lap { op: Option<String> },
    /// Stop the active stopwatch and start another in one step (the "switch" verb)
    Switch {
        op: String,
        /// Recurring lap interval for the new op (defaults to config `default_lap`)
        #[arg(long)]
        lap: Option<String>,
        /// Play a sound when a lap boundary fires
        #[arg(long)]
        sound: bool,
    },
    /// Show current stopwatches. `--json` emits the Waybar module object.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Per-operation time today (+ current lap). `--json` for machine output.
    Stats {
        /// Restrict to one operation
        #[arg(long)]
        op: Option<String>,
        /// (accepted for symmetry; today is the only window in Phase 1)
        #[arg(long)]
        today: bool,
        #[arg(long)]
        json: bool,
    },
    /// Remove a stopwatch from live state (events are kept). Defaults to the active one.
    Reset {
        op: Option<String>,
        /// Remove every stopwatch
        #[arg(long)]
        all: bool,
    },
    /// The task queue: the head runs with its own lap; a timeout runs it again until
    /// `done`. No action lists it (`--json` for the panel). Positions are 1-based.
    Queue {
        #[command(subcommand)]
        action: Option<QueueCmd>,
        #[arg(long)]
        json: bool,
    },
    /// Finish the head task: it leaves the queue and the next one starts
    Done,
    /// Turn an alert on or off at runtime (flips it when no state is given).
    /// `flash` covers the screen flash and the bar blink in a lap's last 10 seconds.
    Toggle {
        #[arg(value_enum)]
        alert: Alert,
        #[arg(value_enum)]
        state: Option<OnOff>,
    },
    /// Print the resolved config + paths
    Config,
}

#[derive(Subcommand)]
enum QueueCmd {
    /// Append a task, e.g. `queue add guitar 5m` (the op may have spaces)
    Add {
        #[arg(required = true, num_args = 1..)]
        task: Vec<String>,
    },
    /// Remove the task at position N
    Rm { n: usize },
    /// Move the task at position N to position TO
    Mv { n: usize, to: usize },
    /// Start working the queue (the head runs)
    Go,
    /// Replace the queue with a preset from config (`[presets]`). No name lists them.
    Load { name: Option<String> },
    /// Empty the queue (stops the head)
    Clear,
}

#[derive(Clone, Copy, ValueEnum)]
enum Alert {
    Sound,
    Flash,
}

#[derive(Clone, Copy, ValueEnum)]
enum OnOff {
    On,
    Off,
}

/// Seconds before a lap boundary during which the bar blinks.
const FINAL_SECS: i64 = 10;

fn sound_on(cfg: &config::Config, snap: &Snapshot) -> bool {
    snap.alerts.sound.unwrap_or(cfg.sound)
}

fn flash_on(cfg: &config::Config, snap: &Snapshot) -> bool {
    snap.alerts.flash.unwrap_or(cfg.flash)
}

fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}

/// Restore default SIGPIPE handling so piping into `head`/`less` exits quietly instead of
/// panicking (Rust ignores SIGPIPE by default). Same convention as notes-cli.
#[cfg(unix)]
fn reset_sigpipe() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
}
#[cfg(not(unix))]
fn reset_sigpipe() {}

fn main() -> Result<()> {
    reset_sigpipe();
    let cli = Cli::parse();
    let cfg = config::resolve()?;
    let log = logging::Logger::new(cfg.log_file.clone(), cli.verbose);

    let now: DateTime<Local> = match &cli.now {
        Some(s) => DateTime::parse_from_rfc3339(s)
            .with_context(|| format!("bad --now timestamp '{s}'"))?
            .with_timezone(&Local),
        None => Local::now(),
    };

    let mut snap = store::load_snapshot(&cfg.state_path);

    // Global lap catch-up: flush every boundary that came due up to `now`, BEFORE the
    // command applies. Fires notifications, appends lap events, marks state dirty. This is
    // also what makes non-`status` commands flush laps the Waybar poll may have missed.
    let laps = snap.catch_up(now);
    if !laps.is_empty() {
        fire_laps(&cfg, &snap, &laps, &log);
        for e in &laps {
            let _ = store::append_event(&cfg.events_path, e);
        }
    }
    let mut dirty = !laps.is_empty();

    let code = run(&cli.cmd, &cfg, &log, &mut snap, now, &mut dirty)?;

    if dirty {
        store::save_snapshot(&cfg.state_path, &snap)
            .with_context(|| format!("writing snapshot {}", cfg.state_path.display()))?;
    }
    std::process::exit(code);
}

fn run(
    cmd: &Cmd,
    cfg: &config::Config,
    log: &logging::Logger,
    snap: &mut Snapshot,
    now: DateTime<Local>,
    dirty: &mut bool,
) -> Result<i32> {
    let sound_opt = |flag: bool| if flag || cfg.sound { Some(true) } else { None };
    let lap_opt = |lap: &Option<String>| -> Result<Option<u64>> {
        match lap {
            Some(s) => Ok(Some(dur::parse_duration(s).map_err(anyhow::Error::msg)?)),
            None => Ok(cfg.default_lap_s),
        }
    };

    match cmd {
        Cmd::Start { op, lap, sound } => {
            let evs = snap.start(now, op, lap_opt(lap)?, sound_opt(*sound));
            persist(cfg, snap, &evs, dirty);
            log.info("start", op);
            println!("started {op}");
            print_one(snap, op, now);
            Ok(0)
        }
        Cmd::Stop { op, all } => {
            let targets = targets(snap, op.as_deref(), *all, "stop")?;
            if targets.is_empty() {
                return Ok(1);
            }
            for t in &targets {
                let evs = snap.stop(now, t);
                persist(cfg, snap, &evs, dirty);
                log.info("stop", t);
                println!("stopped {t}");
            }
            Ok(0)
        }
        Cmd::Pause { op } => single(
            snap,
            op.as_deref(),
            "pause",
            |s, o| s.pause(now, o),
            cfg,
            log,
            dirty,
            now,
        ),
        Cmd::Resume { op } => single(
            snap,
            op.as_deref(),
            "resume",
            |s, o| s.resume(now, o),
            cfg,
            log,
            dirty,
            now,
        ),
        Cmd::Lap { op } => single(
            snap,
            op.as_deref(),
            "lap",
            |s, o| s.lap(now, o),
            cfg,
            log,
            dirty,
            now,
        ),
        Cmd::Switch { op, lap, sound } => {
            let evs = snap.switch(now, op, lap_opt(lap)?, sound_opt(*sound));
            persist(cfg, snap, &evs, dirty);
            log.info("switch", op);
            println!("switched to {op}");
            print_one(snap, op, now);
            Ok(0)
        }
        Cmd::Status { json } => {
            if *json {
                println!("{}", waybar_json(snap, cfg, now));
            } else {
                print_status(snap, now);
                println!(
                    "alerts: sound {}, flash {}",
                    on_off(sound_on(cfg, snap)),
                    on_off(flash_on(cfg, snap))
                );
            }
            Ok(0)
        }
        Cmd::Stats { op, today: _, json } => {
            print_stats(cfg, snap, op.as_deref(), *json, now);
            Ok(0)
        }
        Cmd::Reset { op, all } => {
            let targets = targets(snap, op.as_deref(), *all, "reset")?;
            if targets.is_empty() {
                return Ok(1);
            }
            for t in &targets {
                let evs = snap.reset(now, t);
                persist(cfg, snap, &evs, dirty);
                log.info("reset", t);
                println!("reset {t}");
            }
            Ok(0)
        }
        Cmd::Queue { action, json } => {
            let snd = sound_on(cfg, snap);
            let evs = match action {
                None => {
                    if *json {
                        println!("{}", queue_json(snap, now));
                    } else {
                        print_queue(snap, now);
                    }
                    return Ok(0);
                }
                Some(QueueCmd::Add { task }) => {
                    let t = config::parse_task(&task.join(" ")).map_err(anyhow::Error::msg)?;
                    snap.queue_add(now, t)
                }
                Some(QueueCmd::Rm { n }) => snap.queue_rm(now, pos(*n)?, snd),
                Some(QueueCmd::Mv { n, to }) => snap.queue_mv(now, pos(*n)?, pos(*to)?, snd),
                Some(QueueCmd::Go) => snap.queue_go(now, snd),
                Some(QueueCmd::Clear) => snap.queue_clear(now),
                Some(QueueCmd::Load { name: None }) => {
                    if cfg.presets.is_empty() {
                        eprintln!(
                            "no presets configured (add a [presets] table to {})",
                            cfg.source
                        );
                        return Ok(1);
                    }
                    for (n, tasks) in &cfg.presets {
                        println!("{n}: {}", config::fmt_tasks(tasks));
                    }
                    return Ok(0);
                }
                Some(QueueCmd::Load { name: Some(name) }) => {
                    let Some(tasks) = cfg.presets.get(name) else {
                        eprintln!(
                            "no preset '{name}' (configured: {})",
                            cfg.presets.keys().cloned().collect::<Vec<_>>().join(", ")
                        );
                        return Ok(1);
                    };
                    snap.queue_load(now, name, tasks.clone())
                }
            };
            if evs.is_empty() {
                eprintln!("queue: nothing to do");
                return Ok(1);
            }
            persist(cfg, snap, &evs, dirty);
            log.info(
                "queue",
                &evs.iter()
                    .map(|e| format!("{:?} {}", e.kind, e.op))
                    .collect::<Vec<_>>()
                    .join(", "),
            );
            print_queue(snap, now);
            Ok(0)
        }
        Cmd::Done => {
            let evs = snap.done(now, sound_on(cfg, snap));
            if evs.is_empty() {
                eprintln!("done: the queue is empty");
                return Ok(1);
            }
            persist(cfg, snap, &evs, dirty);
            log.info("done", &evs[0].op);
            println!("done {}", evs[0].op);
            print_queue(snap, now);
            Ok(0)
        }
        Cmd::Toggle { alert, state } => {
            let (cur, slot) = match alert {
                Alert::Sound => (sound_on(cfg, snap), &mut snap.alerts.sound),
                Alert::Flash => (flash_on(cfg, snap), &mut snap.alerts.flash),
            };
            let next = match state {
                Some(OnOff::On) => true,
                Some(OnOff::Off) => false,
                None => !cur,
            };
            *slot = Some(next);
            *dirty = true;
            let label = match alert {
                Alert::Sound => "sound",
                Alert::Flash => "flash",
            };
            log.info("toggle", &format!("{label} {}", on_off(next)));
            println!("{label} {}", on_off(next));
            Ok(0)
        }
        Cmd::Config => {
            config::print(cfg);
            Ok(0)
        }
    }
}

fn persist(cfg: &config::Config, _snap: &Snapshot, evs: &[timebox_core::Event], dirty: &mut bool) {
    for e in evs {
        let _ = store::append_event(&cfg.events_path, e);
    }
    if !evs.is_empty() {
        *dirty = true;
    }
}

/// Resolve the target list for stop/reset (`--all`, an explicit op, or the active one).
fn targets(snap: &Snapshot, op: Option<&str>, all: bool, verb: &str) -> Result<Vec<String>> {
    if all {
        return Ok(snap.stopwatches.keys().cloned().collect());
    }
    match snap.resolve(op) {
        Some(t) => Ok(vec![t]),
        None => {
            match op {
                Some(o) => eprintln!("no stopwatch '{o}' to {verb}"),
                None => eprintln!("no active stopwatch to {verb} (name one, or use --all)"),
            }
            Ok(vec![])
        }
    }
}

/// Apply a single-target transition (pause/resume/lap) to the active-or-named stopwatch.
fn single(
    snap: &mut Snapshot,
    op: Option<&str>,
    verb: &str,
    f: impl FnOnce(&mut Snapshot, &str) -> Vec<timebox_core::Event>,
    cfg: &config::Config,
    log: &logging::Logger,
    dirty: &mut bool,
    now: DateTime<Local>,
) -> Result<i32> {
    let Some(t) = snap.resolve(op) else {
        match op {
            Some(o) => eprintln!("no stopwatch '{o}' to {verb}"),
            None => eprintln!("no active stopwatch to {verb}"),
        }
        return Ok(1);
    };
    let evs = f(snap, &t);
    if evs.is_empty() {
        eprintln!("{verb}: {t} not in a state to {verb}");
        return Ok(1);
    }
    persist(cfg, snap, &evs, dirty);
    log.info(verb, &t);
    println!("{verb} {t}");
    print_one(snap, &t, now);
    Ok(0)
}

fn state_label(s: RunState) -> &'static str {
    match s {
        RunState::Running => "running",
        RunState::Paused => "paused",
        RunState::Stopped => "stopped",
    }
}

fn print_one(snap: &Snapshot, op: &str, now: DateTime<Local>) {
    if let Some(sw) = snap.stopwatches.get(op) {
        let mut line = format!(
            "  {op}  {}  {}",
            state_label(sw.state),
            fmt_hms(sw.elapsed_s(now))
        );
        if let Some(cd) = sw.next_lap_countdown_s(now) {
            line.push_str(&format!("  next switch in {}", fmt_hms(cd)));
        }
        println!("{line}");
    }
}

/// A 1-based queue position from the CLI.
fn pos(n: usize) -> Result<usize> {
    n.checked_sub(1)
        .ok_or_else(|| anyhow::anyhow!("positions start at 1"))
}

/// The head's countdown while the queue is on (None when off or paused).
fn head_countdown(snap: &Snapshot, now: DateTime<Local>) -> Option<i64> {
    let h = snap.queue.head()?;
    if !snap.queue.active {
        return None;
    }
    snap.stopwatches.get(&h.op)?.next_lap_countdown_s(now)
}

/// One line per task: `1  guitar  5m  running 3:12 left  x1`. The panel parses the
/// leading position, so it stays first.
fn queue_lines(snap: &Snapshot, now: DateTime<Local>) -> Vec<String> {
    snap.queue
        .tasks
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let mut l = format!("{:<2} {:<16} {:>4}", i + 1, t.op, fmt_short(t.len_s));
            if i == 0 && snap.queue.active {
                let st = snap.stopwatches.get(&t.op).map(|s| s.state);
                match (st, head_countdown(snap, now)) {
                    (Some(RunState::Running), Some(cd)) => {
                        l.push_str(&format!("  running {} left", fmt_hms(cd)))
                    }
                    (Some(RunState::Paused), _) => l.push_str("  paused"),
                    _ => {}
                }
                let m = snap.queue_misses();
                if m > 0 {
                    l.push_str(&format!("  x{m} missed"));
                }
            }
            l
        })
        .collect()
}

fn print_queue(snap: &Snapshot, now: DateTime<Local>) {
    if snap.queue.tasks.is_empty() {
        println!("queue empty");
        return;
    }
    let state = if snap.queue.active {
        "on"
    } else {
        "off (queue go starts it)"
    };
    match &snap.queue.preset {
        Some(p) => println!("queue {state}, preset {p}"),
        None => println!("queue {state}"),
    }
    for l in queue_lines(snap, now) {
        println!("{l}");
    }
}

fn queue_json(snap: &Snapshot, now: DateTime<Local>) -> String {
    serde_json::json!({
        "active": snap.queue.active,
        "preset": snap.queue.preset,
        "misses": snap.queue_misses(),
        "countdown_s": head_countdown(snap, now),
        "tasks": snap.queue.tasks,
    })
    .to_string()
}

fn print_status(snap: &Snapshot, now: DateTime<Local>) {
    if !snap.queue.tasks.is_empty() {
        print_queue(snap, now);
        println!();
    }
    if snap.stopwatches.is_empty() {
        println!("no stopwatches");
        return;
    }
    for (op, sw) in &snap.stopwatches {
        let star = if snap.active_sw.as_deref() == Some(op) {
            "*"
        } else {
            " "
        };
        let mut line = format!(
            "{star} {op:<14} {:<8} {}",
            state_label(sw.state),
            fmt_hms(sw.elapsed_s(now))
        );
        if let Some(cd) = sw.next_lap_countdown_s(now) {
            line.push_str(&format!(
                "   switch in {}  (lap {})",
                fmt_hms(cd),
                sw.lap_index + 1
            ));
        }
        println!("{line}");
    }
}

/// Build the Waybar module JSON: `{text, tooltip, class}`.
fn waybar_json(snap: &Snapshot, cfg: &config::Config, now: DateTime<Local>) -> String {
    let obj = match snap.display_op() {
        None => {
            let waiting = snap.queue.tasks.len();
            let text = if waiting > 0 {
                format!("{}{} +{waiting}", cfg.icon, cfg.idle_text)
            } else {
                format!("{}{}", cfg.icon, cfg.idle_text)
            };
            let tip = if waiting > 0 {
                tooltip(cfg, snap, now)
            } else {
                "timebox: idle (click to open the queue)".to_string()
            };
            serde_json::json!({ "text": text, "tooltip": tip, "class": "inactive" })
        }
        Some(op) => {
            let sw = &snap.stopwatches[&op];
            let running = sw.state == RunState::Running;
            let (body, class) = match sw.next_lap_countdown_s(now) {
                Some(cd) => {
                    let cls = if !running {
                        "inactive"
                    } else if cd <= FINAL_SECS
                        && sw.lap_len_s.unwrap_or(0) as i64 > FINAL_SECS
                        && flash_on(cfg, snap)
                    {
                        "final"
                    } else if cd <= 60 {
                        "urgent"
                    } else if cd <= 300 {
                        "active"
                    } else {
                        "ready"
                    };
                    (format!("{} {}", op, fmt_hms(cd)), cls)
                }
                None => {
                    let cls = if running { "active" } else { "inactive" };
                    (format!("{} {}", op, fmt_hms(sw.elapsed_s(now))), cls)
                }
            };
            // On the queue head: misses, then the tasks waiting behind it.
            let mut body = body;
            let mut class = class;
            if snap.queue.active && snap.queue.head().map(|t| t.op.as_str()) == Some(op.as_str()) {
                let m = snap.queue_misses();
                if m > 0 {
                    body.push_str(&format!(" x{m}"));
                    if running && class != "final" {
                        class = "overdue";
                    }
                }
                let behind = snap.queue.tasks.len() - 1;
                if behind > 0 {
                    body.push_str(&format!(" (+{behind})"));
                }
            }
            let text = format!("{}{}", cfg.icon, body);
            serde_json::json!({ "text": text, "tooltip": tooltip(cfg, snap, now), "class": class })
        }
    };
    obj.to_string()
}

fn tooltip(cfg: &config::Config, snap: &Snapshot, now: DateTime<Local>) -> String {
    let mut lines = vec!["timebox".to_string()];
    if !snap.queue.tasks.is_empty() {
        lines.push(
            if snap.queue.active {
                "queue:"
            } else {
                "queue (off):"
            }
            .to_string(),
        );
        lines.extend(queue_lines(snap, now));
    }
    for (op, sw) in &snap.stopwatches {
        let mut l = format!(
            "{}: {} {}",
            op,
            state_label(sw.state),
            fmt_hms(sw.elapsed_s(now))
        );
        if let Some(cd) = sw.next_lap_countdown_s(now) {
            l.push_str(&format!(
                " -> switch in {} (lap {})",
                fmt_hms(cd),
                sw.lap_index + 1
            ));
        }
        lines.push(l);
    }
    lines.push(format!(
        "alerts: sound {}, flash {}",
        on_off(sound_on(cfg, snap)),
        on_off(flash_on(cfg, snap))
    ));
    lines.join("\n")
}

fn print_stats(
    cfg: &config::Config,
    snap: &Snapshot,
    filter: Option<&str>,
    json: bool,
    now: DateTime<Local>,
) {
    let events = store::read_events(&cfg.events_path);
    let mut totals = stats::today_totals(&events, now);
    if let Some(f) = filter {
        totals.retain(|k, _| k == f);
    }
    // current lap index per stopwatch still in live state
    let laps: BTreeMap<String, u32> = snap
        .stopwatches
        .iter()
        .filter(|(k, _)| filter.map_or(true, |f| *k == f))
        .map(|(k, v)| (k.clone(), v.lap_index))
        .collect();

    if json {
        let out = serde_json::json!({
            "today_seconds": totals,
            "laps": laps,
        });
        println!("{out}");
        return;
    }

    if totals.is_empty() {
        println!("no time logged today");
    } else {
        println!("today:");
        for (op, secs) in &totals {
            let lap = laps.get(op).copied().unwrap_or(0);
            println!("  {op:<14} {:>8}   ({lap} laps)", fmt_hms(*secs));
        }
    }
}

fn fire_laps(
    cfg: &config::Config,
    snap: &Snapshot,
    evs: &[timebox_core::Event],
    log: &logging::Logger,
) {
    let sound_for = |op: &str| {
        snap.alerts
            .sound
            .unwrap_or_else(|| snap.stopwatches.get(op).map(|s| s.sound).unwrap_or(false))
    };
    let head = snap
        .queue
        .head()
        .filter(|_| snap.queue.active)
        .map(|t| t.op.as_str());
    let mut msgs = Vec::new();
    let mut play = false;

    // Laps grouped by op: how many boundaries crossed and the latest lap index.
    let mut per_op: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    for e in evs.iter().filter(|e| e.kind == EventKind::Lap) {
        let entry = per_op.entry(e.op.clone()).or_insert((0, 0));
        entry.0 += 1;
        if let Some(i) = e.lap_index {
            entry.1 = entry.1.max(i);
        }
    }
    for (op, (count, idx)) in per_op {
        msgs.push(if head == Some(op.as_str()) {
            format!(
                "time's up, again: {op} (x{} missed, timebox done clears it)",
                snap.queue_misses()
            )
        } else if count > 1 {
            format!("missed {count} laps - switch now: {op} (lap {idx})")
        } else {
            format!("switch now: {op} (lap {idx})")
        });
        play |= sound_for(&op);
    }

    if msgs.is_empty() {
        return;
    }
    for msg in &msgs {
        notify::notify("Timebox", "high", msg);
        log.info("lap", msg);
    }
    if play {
        if let Some(f) = &cfg.sound_file {
            notify::play_sound(f);
        }
    }
    // One screen flash per catch-up (not per op).
    if flash_on(cfg, snap) {
        notify::flash(&cfg.flash_cmd);
    }
}
