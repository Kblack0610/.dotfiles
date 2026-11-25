//! One read of every live agent session: the tmux panes joined to `~/.claude/sessions` through
//! the process tree, with each session's account, pending ask, parked ledger and transcript facts.
//! The one definition of a session every view reads (the agent panel, hub-core, agent-web), and
//! of the `list --json` line shell callers read (`ListRow`).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::{account, asks, names, parked, procmap::ProcMap, session, tmux, transcript};

/// One detected Claude agent, ready to render.
#[derive(Clone, Debug, Default)]
pub struct Agent {
    pub glyph: char,
    pub target: String,       // session:window
    pub short_target: String, // display target under the project header
    pub project: String,
    pub repo_full: String, // basename incl. worktree suffix, for preview header
    pub summary: String,
    pub jsonl: Option<PathBuf>,
    /// Window tags (Prefix+t, see tags.sh). Empty when the window is untagged.
    pub tags: String,
    /// Fleet stage and labels from the window (`tmux::Pane`). Display only: never put them in
    /// `list --json`, which fleet-sessions reads, or the copy would feed its own source.
    pub stage: String,
    pub labels: String,
    /// fleet-dispatch started its session (`tmux::Pane::dispatched`); the A-d view reads it.
    pub dispatched: bool,
    /// `<server>/%<pane>`: the agent's own pane, for callers that type into it.
    pub pane: String,
    pub session_id: String,
    /// The session's working directory, from `~/.claude/sessions` (not the pane's).
    pub cwd: String,
    /// Raw Claude status (`busy`, `idle`, `waiting`, `shell`); `glyph` is its display form.
    pub status: String,
    /// Its permission mode: plan (it will not edit until a plan is approved), manual
    /// (investigate-only, `transcript::Mode`), or neither.
    pub mode: transcript::Mode,
    /// The plan it works, by slug (`transcript::RowInfo::plan_slug`); empty for none.
    pub plan_slug: String,
    /// The id of a pending ask (`agent-ask`) it owns, so it is waiting on the human: `asks.rs`.
    pub ask: Option<String>,
    /// Epoch seconds the session opened (the Claude process start), when Claude recorded it.
    pub started_at: Option<u64>,
    /// The tmux server and session name the target is made of.
    pub server: String,
    pub tmux_session: String,
    /// tmux's window id (`@3`), empty for a parked row whose window is not live.
    pub window_id: String,
    /// The claude process; 0 for a parked row, whose claude has exited.
    pub pid: u32,
    /// It is the active window of a tmux session a client is attached to: the human is looking at it.
    pub attached: bool,
    /// The Claude account it runs on (a name from the claude-acct accounts file): `account.rs`.
    pub account: String,
    /// Parked by `claude-acct park`: its claude exited and a ledger holds the resume (`parked.rs`).
    pub parked: bool,
    /// The harness of a run that is not a Claude (a `procmap::HARNESSES` name), empty for a Claude:
    /// `harness_agent`. `pid` is its harness process, and `rollout` the thread file a Codex run
    /// writes, which dates its last activity.
    pub harness: &'static str,
    pub rollout: Option<PathBuf>,
    /// Epoch seconds of its last activity: the transcript's (or rollout's) last write or, for a
    /// harness row, its pane's last output, whichever is later; else the process start. Filled by `write_rows` for the recent sort; display only, like `stage`.
    pub last_active: Option<u64>,
    /// Epoch seconds of a harness row's pane output (`tmux::Pane::activity`); 0 for a Claude row,
    /// which its transcript dates, and for a parked row.
    pub activity: u64,
}

impl Agent {
    /// Waiting on the human, the fleet's NEEDS (`~/.local/src/docs/fleet-states.md`): at a
    /// prompt or dialog (`!`, a plan to approve included) or holding a pending ask. Idle in plan
    /// mode with no dialog open waits on nothing, as fleet-sessions reads it since #1360. A
    /// question asked only in the conversation is not a source: the Stop check makes the
    /// session file it.
    pub fn needs_attention(&self) -> bool {
        self.at_dialog() || self.ask.is_some()
    }

    /// At a prompt or dialog in its own pane this moment (`!`), a plan to approve included.
    pub fn at_dialog(&self) -> bool {
        self.glyph == '!'
    }
}

/// Walk every tmux pane, keep those whose process tree contains a live Claude
/// session, and build an ordered agent list.
pub fn collect() -> Vec<Agent> {
    collect_read().0
}

/// What one read of the live agents could not see, one line per source that failed: a live
/// tmux server's panes, `ps`, a live claude's session file. Empty when the read was whole. A
/// view can show a partial list; a caller that decides a session is gone must not (ar-916).
pub type Gaps = Vec<String>;

/// `collect`, and what that read could not see.
pub fn collect_read() -> (Vec<Agent>, Gaps) {
    let (panes, mut gaps) = tmux::list_panes();
    let (agents, more) = live(panes, &asks::pending_sessions(&asks::root()));
    gaps.extend(more);
    (agents, gaps)
}

fn live(panes: Vec<tmux::Pane>, asking: &HashMap<String, String>) -> (Vec<Agent>, Gaps) {
    let procmap = match ProcMap::capture() {
        Ok(p) => p,
        Err(e) => return (Vec::new(), vec![format!("{e:#}")]),
    };
    let (sessions, unreadable) = session::load_all();
    let gaps: Gaps = unreadable
        .into_iter()
        .filter(|&pid| procmap.is_live(pid))
        .map(|pid| format!("~/.claude/sessions/{pid}.json would not read, and pid {pid} is live"))
        .collect();
    let accounts = account::load();
    let (proc_root, home) = (account::proc_root(), session::home());
    let live_claude: Vec<u32> = sessions
        .keys()
        .copied()
        .filter(|&pid| procmap.is_live(pid))
        .collect();
    let pane_to_claude = procmap.pane_to_claude(&live_claude);

    let mut seen = HashSet::new();
    let mut agents = Vec::new();
    let mut others = Vec::new();
    for pane in panes {
        let target = tmux::qualify(&pane.server, &pane.session, &pane.window_index);
        let Some(&cpid) = pane_to_claude.get(&pane.pid) else {
            if let Some((xpid, harness)) = procmap.harness_below(pane.pid) {
                others.push((pane, target, xpid, harness));
            }
            continue; // not a Claude agent
        };
        let Some(sess) = sessions.get(&cpid) else {
            continue;
        };
        // One row per window, and that row is its Claude pane wherever the split put it.
        if !seen.insert(target.clone()) {
            continue;
        }

        let jsonl_path = session::jsonl_path(&sess.session_id, &sess.cwd);
        // Claude's pane title (the live session title) wins over the JSONL "say:" text filled in
        // below; the row glyph already conveys status.
        let summary = names::strip_title_glyph(&pane.title);

        let project = project_map::project_for_path(&pane.current_path);
        let repo_full = names::basename(&pane.current_path).to_string();
        let short_target = names::short_target(&pane.session, &pane.window_index);

        agents.push(Agent {
            glyph: session::glyph(&sess.status),
            target,
            short_target,
            project,
            repo_full,
            summary,
            jsonl: jsonl_path.exists().then_some(jsonl_path),
            tags: pane.tags.clone(),
            stage: pane.stage.clone(),
            labels: pane.labels.clone(),
            dispatched: pane.dispatched,
            pane: format!("{}/{}", pane.server, pane.pane_id),
            session_id: sess.session_id.clone(),
            cwd: sess.cwd.clone(),
            status: sess.status.clone(),
            mode: transcript::Mode::Other,
            plan_slug: String::new(),
            ask: asking.get(&sess.session_id).cloned(),
            started_at: sess.started_at.map(|ms| ms / 1000),
            server: pane.server.clone(),
            tmux_session: pane.session.clone(),
            window_id: pane.window_id.clone(),
            pid: cpid,
            attached: pane.attached,
            account: account::of_pid(&proc_root, cpid, &home, &accounts),
            parked: false,
            harness: "",
            rollout: None,
            last_active: None,
            // Its transcript dates a Claude, never the pane (a sibling split, or a redraw).
            activity: 0,
        });
    }
    // Side by side, since each transcript is read whole (par_map).
    let infos = par_map(&agents, |a| a.jsonl.as_deref().map(transcript::row_info));
    for (a, info) in agents.iter_mut().zip(infos) {
        let Some(info) = info else { continue };
        if a.summary.is_empty() {
            a.summary = info.summary;
        }
        a.mode = info.mode;
        a.plan_slug = info.plan_slug;
    }
    // After every Claude pane, so a window with a Claude in one split stays that Claude's row.
    let now = crate::now_secs();
    for (pane, target, xpid, harness) in others {
        if !seen.contains(&target) {
            if let Some(a) = harness_agent(&pane, target, xpid, harness, &proc_root, now) {
                seen.insert(a.target.clone());
                agents.push(a);
            }
        }
    }
    (agents, gaps)
}

/// A row for a run on another harness in `pane` (`xpid` its `harness` process), so the fleet's views
/// see it too. It keeps no `~/.claude/sessions` file, so the row is read from the process: the queue
/// item fleet-dispatch launched it for (`AGENT_QUEUE_ITEM` in its environment) and its session id,
/// the one claimed on that item: a Codex run's thread (its open rollout file, claimed by agent-codex),
/// an opencode's `--session` argument (claimed by fleet-dispatch), an agy's `--conversation`
/// argument. It keeps no status file, so its status is the one reading any harness gets
/// (`activity_status`): busy while it wrote its rollout or drew in its pane within
/// `HARNESS_IDLE_SECS` before `now`, idle after. Its transcript is not Claude's, so `jsonl` stays empty.
/// An opencode with no `run` argument is a headless run's replay, its TUI on the finished run's
/// transcript (fleet-dispatch gateway_launch), so it reads as done. The summary names the run's pair
/// (`AGENT_RUN_PAIR`, harness:model, else the harness) and, once it ended, what it left
/// (`AGENT_RUN_RESULT`, `fleet-dispatch run-result`).
/// An opencode with no queue item is the human's own (`ocp`), not a fleet run, so it gets no row;
/// a codex or agy the human started in a pane keeps one, so the panel shows the pane it runs in.
fn harness_agent(
    pane: &tmux::Pane,
    target: String,
    xpid: u32,
    harness: &'static str,
    proc_root: &Path,
    now: u64,
) -> Option<Agent> {
    let item = account::env_of(proc_root, xpid, "AGENT_QUEUE_ITEM");
    if harness == "opencode" && item.is_empty() {
        return None;
    }
    let rollout = (harness == "codex")
        .then(|| codex_rollout(proc_root, xpid))
        .flatten();
    let session_id = match &rollout {
        Some(r) => thread_of_rollout(&r.file_name().unwrap_or_default().to_string_lossy()),
        None if harness == "agy" => arg_after(proc_root, xpid, "--conversation"),
        None => arg_after(proc_root, xpid, "--session"),
    };
    let status = if harness == "opencode" && has_arg(proc_root, xpid, "run") == Some(false) {
        "done"
    } else {
        activity_status(last_write(rollout.as_deref(), pane.activity), now)
    };
    let pair = account::env_of(proc_root, xpid, "AGENT_RUN_PAIR");
    let label = if pair.is_empty() {
        harness
    } else {
        pair.as_str()
    };
    // Only a replay carries a result: the run itself has none yet.
    let result = if status == "done" {
        account::env_of(proc_root, xpid, "AGENT_RUN_RESULT")
    } else {
        String::new()
    };
    let summary = match (item.is_empty(), result.is_empty()) {
        (true, _) => label.to_string(),
        (false, true) => format!("{label}: {item}"),
        (false, false) => format!("{label}: {item}, {result}"),
    };
    Some(Agent {
        glyph: session::glyph(status),
        short_target: names::short_target(&pane.session, &pane.window_index),
        project: project_map::project_for_path(&pane.current_path),
        repo_full: names::basename(&pane.current_path).to_string(),
        summary,
        tags: pane.tags.clone(),
        stage: pane.stage.clone(),
        labels: pane.labels.clone(),
        dispatched: pane.dispatched,
        pane: format!("{}/{}", pane.server, pane.pane_id),
        session_id: session_id.unwrap_or_default(),
        cwd: pane.current_path.clone(),
        status: status.into(),
        server: pane.server.clone(),
        tmux_session: pane.session.clone(),
        window_id: pane.window_id.clone(),
        pid: xpid,
        attached: pane.attached,
        account: harness.into(),
        harness,
        rollout,
        started_at: proc_started(proc_root, xpid),
        activity: pane.activity,
        target,
        ..Agent::default()
    })
}

/// How long a harness may go without writing before it reads idle. A working harness redraws
/// its pane (a spinner or an elapsed-time counter) every second or so, and a Codex run appends
/// to its rollout, so a minute of neither is a run at its prompt.
pub const HARNESS_IDLE_SECS: u64 = 60;

/// The busy or idle of a session that reports no status of its own, whatever its harness:
/// `busy` while its last write (`last_write`) is under `HARNESS_IDLE_SECS` old, else `idle`.
/// A write never read (0: no rollout, and a tmux without `pane_last_output_time`) reads busy, as
/// every harness row did before this reading, so a missing reading never parks a working run.
fn activity_status(last_write: u64, now: u64) -> &'static str {
    if last_write == 0 || now.saturating_sub(last_write) < HARNESS_IDLE_SECS {
        "busy"
    } else {
        "idle"
    }
}

/// A session's last write: its transcript or rollout file's mtime, or its pane's last output,
/// whichever is later; 0 when neither was read.
fn last_write(file: Option<&Path>, activity: u64) -> u64 {
    mtime_secs(file).max(activity)
}

/// Epoch seconds process `pid` started: its start in clock ticks after boot (`/proc/<pid>/stat`
/// field 22) plus the boot time (`btime` in `/proc/stat`). None when either cannot be read (no
/// `/proc`, as on macOS). Linux reports these ticks at USER_HZ, which is 100.
fn proc_started(proc_root: &Path, pid: u32) -> Option<u64> {
    const USER_HZ: u64 = 100;
    let stat = fs::read_to_string(proc_root.join(pid.to_string()).join("stat")).ok()?;
    // Fields after the parenthesised comm, which may hold spaces: state is field 3, starttime 22.
    let ticks: u64 = stat
        .rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)?
        .parse()
        .ok()?;
    let btime: u64 = fs::read_to_string(proc_root.join("stat"))
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix("btime ")?.trim().parse().ok())?;
    Some(btime + ticks / USER_HZ)
}

/// The argument after `flag` on process `pid`'s command line; None when it has none or its cmdline
/// cannot be read (no `/proc`, as on macOS).
fn arg_after(proc_root: &Path, pid: u32, flag: &str) -> Option<String> {
    let raw = cmdline(proc_root, pid)?;
    let mut args = raw.split(|b| *b == 0).map(String::from_utf8_lossy);
    args.find(|a| a == flag)?;
    args.next()
        .map(|a| a.into_owned())
        .filter(|a| !a.is_empty())
}

/// Process `pid`'s NUL-separated argv; None when it cannot be read.
fn cmdline(proc_root: &Path, pid: u32) -> Option<Vec<u8>> {
    fs::read(proc_root.join(pid.to_string()).join("cmdline")).ok()
}

/// Whether `arg` is one of process `pid`'s arguments; None when its cmdline cannot be read (no
/// `/proc`, as on macOS), so a run is never read as its replay for want of one.
fn has_arg(proc_root: &Path, pid: u32, arg: &str) -> Option<bool> {
    Some(
        cmdline(proc_root, pid)?
            .split(|b| *b == 0)
            .skip(1)
            .any(|a| a == arg.as_bytes()),
    )
}

/// The rollout file Codex process `pid` holds open (`rollout-<time>-<uuid>.jsonl`, its thread);
/// None when none is open or its fds cannot be read (no `/proc`, as on macOS).
fn codex_rollout(proc_root: &Path, pid: u32) -> Option<PathBuf> {
    fs::read_dir(proc_root.join(pid.to_string()).join("fd"))
        .ok()?
        .filter_map(|e| fs::read_link(e.ok()?.path()).ok())
        .find(|t| {
            t.file_name()
                .is_some_and(|n| thread_of_rollout(&n.to_string_lossy()).is_some())
        })
}

/// `rollout-2026-11-09T10-00-00-<uuid>.jsonl` -> the uuid (the last five dash-separated fields).
fn thread_of_rollout(name: &str) -> Option<String> {
    let stem = name.strip_prefix("rollout-")?.strip_suffix(".jsonl")?;
    let parts: Vec<&str> = stem.rsplitn(6, '-').collect();
    (parts.len() == 6).then(|| {
        let mut id: Vec<&str> = parts[..5].to_vec();
        id.reverse();
        id.join("-")
    })
}

/// The live agents plus a row per parked session, the human's own session first: what a
/// view that acts on sessions lists (agent-web, `list --json --parked`).
pub fn collect_all() -> Vec<Agent> {
    collect_all_read().0
}

/// `collect_all`, and what that read could not see (`Gaps`).
pub fn collect_all_read() -> (Vec<Agent>, Gaps) {
    let (panes, mut gaps) = tmux::list_panes();
    let attached: HashSet<(String, String)> = panes
        .iter()
        .filter(|p| p.attached)
        .map(|p| (p.server.clone(), p.session.clone()))
        .collect();
    let asking = asks::pending_sessions(&asks::root());
    let (agents, more) = live(panes, &asking);
    gaps.extend(more);
    let rows = parked::load(&parked::root());
    let mut all = with_parked(agents, rows, &attached, &asking, &account::load());
    attached_first(&mut all);
    (all, gaps)
}

/// Append a row for each ledger whose tmux session has no live claude: one with a live claude
/// again was resumed by hand, and its live row already stands for it.
pub fn with_parked(
    mut agents: Vec<Agent>,
    ledgers: Vec<parked::Parked>,
    attached: &HashSet<(String, String)>,
    asking: &HashMap<String, String>,
    accounts: &[account::Account],
) -> Vec<Agent> {
    let live: HashSet<(String, String)> = agents
        .iter()
        .map(|a| (a.server.clone(), a.tmux_session.clone()))
        .collect();
    for p in ledgers {
        let key = (p.server.clone(), p.session.clone());
        if live.contains(&key) {
            continue;
        }
        let jsonl_path = session::jsonl_path(&p.session_id, &p.cwd);
        let window = tmux::split(&p.target)
            .1
            .rsplit_once(':')
            .map(|(_, w)| w.to_string())
            .unwrap_or_default();
        agents.push(Agent {
            glyph: 'P',
            short_target: names::short_target(&p.session, &window),
            project: project_map::project_for_path(&p.cwd),
            repo_full: names::basename(&p.cwd).to_string(),
            summary: format!(
                "parked ({})",
                if p.why.is_empty() { "park" } else { &p.why }
            ),
            jsonl: jsonl_path.exists().then_some(jsonl_path),
            pane: format!("{}/{}", p.server, p.pane),
            status: "parked".into(),
            ask: asking.get(&p.session_id).cloned(),
            started_at: None,
            attached: attached.contains(&key),
            account: account::name_of(&p.from, accounts),
            parked: true,
            target: p.target,
            server: p.server,
            tmux_session: p.session,
            session_id: p.session_id,
            cwd: p.cwd,
            ..Agent::default()
        });
    }
    agents
}

/// The sessions the human is attached to first, the rest in their order.
pub fn attached_first(agents: &mut [Agent]) {
    agents.sort_by_key(|a| !a.attached);
}

/// One `agent-panel list --json` line: the session facts fleet-sessions buckets on (status, cwd,
/// plan mode, context size, plan file, the last entry's time as `idle_since`, the process start
/// as `started_at`, `edited_files`), and what an action on the session needs (server, tmux
/// session, window id, claude pid, account, attached, parked, plan slug, ask id).
///
/// The wire contract shell callers read with jq. Fields are in key order, so the line is the one
/// `serde_json::json!` printed before this type held it; `tests::list_row_keys_are_the_contract`
/// pins the set. Display-only facts (`stage`, `labels`, `tags`) stay out: fleet-sessions reads
/// this, and the copy would feed its own source.
#[derive(Debug, serde::Serialize)]
pub struct ListRow<'a> {
    pub account: &'a str,
    pub ask: Option<&'a str>,
    pub attached: bool,
    pub compactions: u64,
    pub context_tokens: u64,
    pub context_window: Option<u64>,
    pub cwd: &'a str,
    pub doing: String,
    pub edited_files: Vec<String>,
    pub harness: &'static str,
    pub human_at: Option<u64>,
    pub idle_since: u64,
    pub manual_mode: bool,
    pub model: String,
    pub open_job: &'static str,
    pub pane: &'a str,
    pub parked: bool,
    pub pid: u32,
    pub plan: &'a str,
    pub plan_file: String,
    pub plan_mode: bool,
    pub project: &'a str,
    pub said: String,
    pub server: &'a str,
    pub session_id: &'a str,
    pub started_at: Option<u64>,
    pub status: &'a str,
    pub summary: &'a str,
    pub target: &'a str,
    pub time_use: transcript::TimeUse,
    pub tmux_session: &'a str,
    pub transcript: String,
    pub window_id: &'a str,
}

/// The `list --json` line for each agent. Each transcript is read whole, so one after another
/// the reads cost their sum; side by side they cost about the largest one.
pub fn list_rows(agents: &[Agent]) -> Vec<ListRow<'_>> {
    let facts = par_map(agents, |a| match &a.jsonl {
        Some(p) => (transcript::fleet_info(p), last_write(Some(p), a.activity)),
        None => (
            transcript::fleet_info(Path::new("")),
            last_write(a.rollout.as_deref(), a.activity),
        ),
    });
    agents
        .iter()
        .zip(facts)
        .map(|(a, (info, mtime))| list_row(a, info, mtime))
        .collect()
}

fn list_row(a: &Agent, info: transcript::FleetInfo, mtime: u64) -> ListRow<'_> {
    ListRow {
        account: &a.account,
        ask: a.ask.as_deref(),
        attached: a.attached,
        compactions: info.compactions,
        context_tokens: info.context_tokens,
        context_window: transcript::context_window(&info.model),
        cwd: &a.cwd,
        doing: info.doing,
        edited_files: info.edited_files,
        harness: if a.harness.is_empty() {
            "claude"
        } else {
            a.harness
        },
        human_at: info.human_at,
        idle_since: idle_since(info.last_entry, mtime, a.started_at),
        manual_mode: a.mode == transcript::Mode::Manual,
        model: info.model,
        open_job: info.open_job,
        pane: &a.pane,
        parked: a.parked,
        pid: a.pid,
        plan: &a.plan_slug,
        plan_file: info.plan_file,
        plan_mode: a.mode == transcript::Mode::Plan,
        project: &a.project,
        said: info.said,
        server: &a.server,
        session_id: &a.session_id,
        started_at: a.started_at,
        status: &a.status,
        summary: &a.summary,
        target: &a.target,
        time_use: info.time_use,
        tmux_session: &a.tmux_session,
        transcript: a
            .jsonl
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default(),
        window_id: &a.window_id,
    }
}

/// Date each row's last activity for the recent sort: one stat of its transcript (or rollout).
pub fn with_last_active(agents: &mut [Agent]) {
    for a in agents {
        let mtime = last_write(a.jsonl.as_deref().or(a.rollout.as_deref()), a.activity);
        a.last_active = Some(idle_since(None, mtime, a.started_at)).filter(|&t| t > 0);
    }
}

/// `f` over `items`, one scoped thread per item (an item is a live session, so tens), results in
/// `items`' order. A panic in `f` panics the caller, as it would in a plain map.
fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let f = &f;
    std::thread::scope(|s| {
        let calls: Vec<_> = items.iter().map(|item| s.spawn(move || f(item))).collect();
        calls
            .into_iter()
            .map(|c| c.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect()
    })
}

/// A file's mtime in epoch seconds; 0 for none or an unreadable one.
fn mtime_secs(p: Option<&Path>) -> u64 {
    p.and_then(|p| fs::metadata(p).and_then(|m| m.modified()).ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs())
}

/// The last entry's own timestamp; the mtime when no entry carries one; with no transcript at
/// all, the process start, since the session cannot have been idle for longer than that.
fn idle_since(last_entry: Option<u64>, mtime: u64, started_at: Option<u64>) -> u64 {
    last_entry.unwrap_or(if mtime > 0 {
        mtime
    } else {
        started_at.unwrap_or(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn par_map_keeps_the_input_order_and_a_panic_reaches_the_caller() {
        let items: Vec<usize> = (0..50).collect();
        assert_eq!(
            par_map(&items, |i| i * 2),
            (0..50).map(|i| i * 2).collect::<Vec<_>>()
        );
        assert_eq!(par_map(&[] as &[usize], |i| *i), Vec::<usize>::new());
        let panicked = std::panic::catch_unwind(|| par_map(&items, |&i| assert_ne!(i, 7)));
        assert!(panicked.is_err());
    }

    #[test]
    fn a_rollout_name_gives_its_thread_id_and_nothing_else_does() {
        assert_eq!(
            thread_of_rollout(
                "rollout-2026-11-09T10-00-00-01a1c3ac-40c2-7282-bafa-0adf7d5ff0a0.jsonl"
            )
            .as_deref(),
            Some("01a1c3ac-40c2-7282-bafa-0adf7d5ff0a0")
        );
        assert_eq!(thread_of_rollout("rollout-x.jsonl"), None);
        assert_eq!(thread_of_rollout("abc.jsonl"), None);
        assert_eq!(
            thread_of_rollout(
                "rollout-2026-11-09T10-00-00-01a1c3ac-40c2-7282-bafa-0adf7d5ff0a0.json"
            ),
            None
        );
    }

    /// A scratch /proc root and a pane in a hub session, for the harness rows below.
    fn harness_fixture(tag: &str) -> (PathBuf, tmux::Pane) {
        let root = std::env::temp_dir().join(format!("agent-core-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let pane = tmux::Pane {
            server: "hub".into(),
            session: "dotfiles-agent-37".into(),
            window_index: "1".into(),
            current_path: "/home/u/.worktrees/dotfiles-agent-37".into(),
            pid: 200,
            pane_id: "%7".into(),
            ..tmux::Pane::default()
        };
        (root, pane)
    }

    #[test]
    fn a_codex_row_is_read_from_its_process_item_and_session() {
        let (root, mut pane) = harness_fixture("codex");
        let now = crate::now_secs();
        let fd = root.join("300").join("fd");
        fs::create_dir_all(&fd).unwrap();
        fs::write(
            root.join("300").join("environ"),
            b"TERM=x\0AGENT_QUEUE_ITEM=codex-parity-p6\0",
        )
        .unwrap();
        let rollout =
            root.join("rollout-2026-11-09T10-00-00-01a1c3ac-40c2-7282-bafa-0adf7d5ff0a0.jsonl");
        fs::write(&rollout, "").unwrap();
        std::os::unix::fs::symlink("/dev/null", fd.join("0")).unwrap();
        std::os::unix::fs::symlink(&rollout, fd.join("5")).unwrap();
        let a = harness_agent(
            &pane,
            "hub/dotfiles-agent-37:1".into(),
            300,
            "codex",
            &root,
            now,
        )
        .unwrap();
        assert_eq!(a.harness, "codex");
        // Busy by its rollout, written just now, though its pane drew nothing.
        assert_eq!(a.status, "busy");
        assert_eq!(a.session_id, "01a1c3ac-40c2-7282-bafa-0adf7d5ff0a0");
        assert_eq!(a.summary, "codex: codex-parity-p6");
        assert_eq!(
            (a.pane.as_str(), a.pid, a.account.as_str()),
            ("hub/%7", 300, "codex")
        );
        assert_eq!(a.rollout.as_deref(), Some(rollout.as_path()));
        assert!(a.jsonl.is_none() && !a.needs_attention());
        // No fds to read (macOS, or a process gone): still a row, with no thread id.
        let b = harness_agent(
            &pane,
            "hub/dotfiles-agent-37:1".into(),
            301,
            "codex",
            &root,
            now,
        )
        .unwrap();
        assert_eq!((b.session_id.as_str(), b.summary.as_str()), ("", "codex"));
        // No rollout and no pane reading: no evidence either way, so it stays busy.
        assert_eq!(b.status, "busy");
        // A pane quiet past the idle window, and no rollout: idle, as a Claude at its prompt.
        pane.activity = now - HARNESS_IDLE_SECS;
        let quiet = harness_agent(
            &pane,
            "hub/dotfiles-agent-37:1".into(),
            301,
            "codex",
            &root,
            now,
        )
        .unwrap();
        assert_eq!(
            (quiet.status.as_str(), quiet.glyph),
            ("idle", session::glyph("idle"))
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_opencode_row_is_read_from_its_process_item_and_session() {
        let (root, mut pane) = harness_fixture("opencode");
        let now = crate::now_secs();
        pane.activity = now;
        // An opencode harness: its session id is its --session argument, and it has no rollout.
        let oc = root.join("400");
        fs::create_dir_all(&oc).unwrap();
        fs::write(oc.join("environ"), b"AGENT_QUEUE_ITEM=canary-x-nim-glm\0").unwrap();
        fs::write(
            oc.join("cmdline"),
            b"opencode\0run\0--standalone\0--session\0ses_eval17\0--title\0t\0",
        )
        .unwrap();
        fs::write(
            oc.join("stat"),
            b"400 (opencode) S 1 400 400 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 9 0 12345 0 0",
        )
        .unwrap();
        fs::write(root.join("stat"), b"cpu  1 2 3\nbtime 1795000000\n").unwrap();
        let o = harness_agent(
            &pane,
            "lab/dotfiles-agent-6:1".into(),
            400,
            "opencode",
            &root,
            now,
        )
        .unwrap();
        assert_eq!(o.started_at, Some(1795000000 + 123));
        assert_eq!(
            (
                o.harness,
                o.session_id.as_str(),
                o.summary.as_str(),
                o.account.as_str()
            ),
            (
                "opencode",
                "ses_eval17",
                "opencode: canary-x-nim-glm",
                "opencode"
            )
        );
        assert!(o.rollout.is_none() && o.status == "busy");
        // The same opencode with its pane quiet past the idle window reads idle too.
        pane.activity = now - HARNESS_IDLE_SECS;
        let quiet = harness_agent(&pane, "lab/x:1".into(), 400, "opencode", &root, now).unwrap();
        assert_eq!(quiet.status, "idle");
        pane.activity = now;
        // A run that names its pair reads as it; its replay (no `run` argument) reads done, with its result.
        let rp = root.join("402");
        fs::create_dir_all(&rp).unwrap();
        fs::write(
            rp.join("environ"),
            b"AGENT_QUEUE_ITEM=t-one\0AGENT_RUN_PAIR=opencode-go:glm\0",
        )
        .unwrap();
        fs::write(
            rp.join("cmdline"),
            b"opencode\0run\0--standalone\0--session\0ses_eval18\0",
        )
        .unwrap();
        let r = harness_agent(&pane, "lab/x:1".into(), 402, "opencode", &root, now).unwrap();
        assert_eq!(
            (r.status.as_str(), r.summary.as_str()),
            ("busy", "opencode-go:glm: t-one")
        );
        fs::write(
            rp.join("environ"),
            b"AGENT_QUEUE_ITEM=t-one\0AGENT_RUN_PAIR=opencode-go:glm\0AGENT_RUN_RESULT=patch written, 1 file, +3 -1\0",
        )
        .unwrap();
        fs::write(
            rp.join("cmdline"),
            b"opencode\0--standalone\0--session\0ses_eval18\0",
        )
        .unwrap();
        let r = harness_agent(&pane, "lab/x:1".into(), 402, "opencode", &root, now).unwrap();
        assert_eq!(
            (
                r.status.as_str(),
                r.glyph,
                r.session_id.as_str(),
                r.summary.as_str()
            ),
            (
                "done",
                session::glyph("done"),
                "ses_eval18",
                "opencode-go:glm: t-one, patch written, 1 file, +3 -1"
            )
        );
        // No cmdline to read (macOS): a run is never taken for its replay.
        fs::remove_file(rp.join("cmdline")).unwrap();
        let r = harness_agent(&pane, "lab/x:1".into(), 402, "opencode", &root, now).unwrap();
        assert_eq!(r.status, "busy");
        // The human's own opencode (no queue item in its environment) is no fleet row.
        fs::create_dir_all(root.join("401")).unwrap();
        fs::write(root.join("401").join("environ"), b"TERM=x\0").unwrap();
        assert!(harness_agent(&pane, "lab/x:1".into(), 401, "opencode", &root, now).is_none());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_agy_row_is_read_from_its_conversation_argument() {
        let (root, mut pane) = harness_fixture("agy");
        let now = crate::now_secs();
        pane.activity = now;
        // An agy, the human's own included: a row, its session id the --conversation argument.
        let ag = root.join("500");
        fs::create_dir_all(&ag).unwrap();
        fs::write(ag.join("environ"), b"TERM=x\0").unwrap();
        fs::write(ag.join("cmdline"), b"agy\0--conversation\0conv-42\0").unwrap();
        let g = harness_agent(&pane, "lab/x:1".into(), 500, "agy", &root, now).unwrap();
        assert_eq!(
            (g.harness, g.session_id.as_str(), g.summary.as_str()),
            ("agy", "conv-42", "agy")
        );
        assert_eq!(g.status, "busy");
        // The same agy with its pane quiet past the idle window reads idle, as every harness does.
        pane.activity = now - HARNESS_IDLE_SECS;
        let quiet = harness_agent(&pane, "lab/x:1".into(), 500, "agy", &root, now).unwrap();
        assert_eq!(quiet.status, "idle");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn activity_reads_busy_inside_the_idle_window_or_unread_and_idle_past_it() {
        let now = 1_800_000_000;
        assert_eq!(activity_status(now, now), "busy");
        assert_eq!(activity_status(now - HARNESS_IDLE_SECS + 1, now), "busy");
        assert_eq!(activity_status(now - HARNESS_IDLE_SECS, now), "idle");
        assert_eq!(activity_status(0, now), "busy");
        // A clock behind the write (another host's mtime) is still a fresh write.
        assert_eq!(activity_status(now + 5, now), "busy");
        assert_eq!(last_write(None, 7), 7);
        assert_eq!(last_write(Some(Path::new("/nonexistent/x")), 0), 0);
    }

    #[test]
    fn idle_since_prefers_the_entry_then_the_mtime_then_the_process_start() {
        assert_eq!(idle_since(Some(30), 20, Some(10)), 30);
        assert_eq!(idle_since(None, 20, Some(10)), 20);
        assert_eq!(idle_since(None, 0, Some(10)), 10);
        assert_eq!(idle_since(None, 0, None), 0);
    }

    fn live_agent(server: &str, sess: &str, attached: bool) -> Agent {
        Agent {
            target: format!("{server}/{sess}:1"),
            server: server.into(),
            tmux_session: sess.into(),
            attached,
            ..Agent::default()
        }
    }

    #[test]
    fn plan_mode_counts_only_with_its_dialog_open() {
        let plan_dialog = Agent {
            glyph: '!',
            mode: transcript::Mode::Plan,
            ..live_agent("hub", "a", false)
        };
        let plan_idle = Agent {
            glyph: '✓',
            mode: transcript::Mode::Plan,
            ..live_agent("hub", "a", false)
        };
        let plan_busy = Agent {
            glyph: '~',
            mode: transcript::Mode::Plan,
            ..live_agent("hub", "b", false)
        };
        assert!(plan_dialog.needs_attention());
        assert!(!plan_idle.needs_attention());
        assert!(!plan_busy.needs_attention());
    }

    #[test]
    fn a_parked_ledger_is_a_row_unless_its_session_is_live_again() {
        let ledgers = vec![
            parked::parse(
                "agent-7",
                "server=lab\ntarget=lab/agent-7:2\npane=%4\nsession_id=sid-7\n\
                 cwd=/nonexistent/wt/dotfiles-agent-7\nfrom=/home/u/.claude-bnb\nwhy=move\n",
            )
            .unwrap(),
            // Resumed by hand: its live row already stands for it.
            parked::parse("agent-1", "server=lab\npane=%1\n").unwrap(),
        ];
        let accounts = account::parse("main -\nbnb /home/u/.claude-bnb\n", Path::new("/home/u"));
        let attached = HashSet::from([("lab".to_string(), "agent-7".to_string())]);
        let asking = HashMap::from([("sid-7".to_string(), "ask-9".to_string())]);
        let got = with_parked(
            vec![live_agent("lab", "agent-1", false)],
            ledgers,
            &attached,
            &asking,
            &accounts,
        );
        assert_eq!(got.len(), 2);
        let p = &got[1];
        assert!(p.parked && p.attached && !got[0].parked);
        assert_eq!(p.target, "lab/agent-7:2");
        assert_eq!(p.pane, "lab/%4");
        assert_eq!(p.account, "bnb");
        assert_eq!(p.ask.as_deref(), Some("ask-9"));
        assert_eq!(p.status, "parked");
        assert_eq!(p.summary, "parked (move)");
        assert_eq!(p.pid, 0);
        assert!(p.jsonl.is_none());
    }

    #[test]
    fn attached_sessions_sort_first_and_the_rest_keep_their_order() {
        let mut v = vec![
            live_agent("lab", "a", false),
            live_agent("hub", "b", true),
            live_agent("lab", "c", false),
            live_agent("lab", "d", true),
        ];
        attached_first(&mut v);
        let order: Vec<&str> = v.iter().map(|a| a.tmux_session.as_str()).collect();
        assert_eq!(order, ["b", "d", "a", "c"]);
    }

    /// The keys of a `list --json` line, which about 25 shell callers read with jq: renaming or
    /// dropping one breaks them with no compile error, so the set is pinned here.
    #[test]
    fn list_row_keys_are_the_contract() {
        let a = live_agent("hub", "a", false);
        let row = list_row(&a, transcript::fleet_info(Path::new("")), 0);
        let v = serde_json::to_value(&row).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            [
                "account",
                "ask",
                "attached",
                "compactions",
                "context_tokens",
                "context_window",
                "cwd",
                "doing",
                "edited_files",
                "harness",
                "human_at",
                "idle_since",
                "manual_mode",
                "model",
                "open_job",
                "pane",
                "parked",
                "pid",
                "plan",
                "plan_file",
                "plan_mode",
                "project",
                "said",
                "server",
                "session_id",
                "started_at",
                "status",
                "summary",
                "target",
                "time_use",
                "tmux_session",
                "transcript",
                "window_id",
            ]
        );
        // Printed in that order too, so a line reads as it did when `json!` built it.
        let line = serde_json::to_string(&row).unwrap();
        assert!(
            line.starts_with(r#"{"account":"","ask":null,"attached":false,"#),
            "{line}"
        );
    }
}
