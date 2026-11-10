//! Orchestration for the three entry points: interactive chooser, `next`, and
//! the internal `preview` callback.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

use crate::{account, asks, fzf, jsonl, parked, procmap::ProcMap, render, search, session, sort, tmux};

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
    /// `<server>/%<pane>`: the agent's own pane, for callers that type into it.
    pub pane: String,
    pub session_id: String,
    /// The session's working directory, from `~/.claude/sessions` (not the pane's).
    pub cwd: String,
    /// Raw Claude status (`busy`, `idle`, `waiting`, `shell`); `glyph` is its display form.
    pub status: String,
    /// Its permission mode: plan (it will not edit until a plan is approved), manual
    /// (investigate-only, `jsonl::Mode`), or neither.
    pub mode: jsonl::Mode,
    /// The plan it works, by slug (`jsonl::RowInfo::plan_slug`); empty for none.
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
    for pane in panes {
        let target = tmux::qualify(&pane.server, &pane.session, &pane.window_index);
        let Some(&cpid) = pane_to_claude.get(&pane.pid) else {
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
        let (mut summary, mode, plan_slug) = if jsonl_path.exists() {
            let info = jsonl::row_info(&jsonl_path);
            (info.summary, info.mode, info.plan_slug)
        } else {
            (String::new(), jsonl::Mode::Other, String::new())
        };
        // Prefer Claude's pane title (the live session title) over the JSONL
        // "say:" text; the row glyph already conveys status.
        if !pane.title.is_empty() {
            let cleaned = render::strip_title_glyph(&pane.title);
            if !cleaned.is_empty() {
                summary = cleaned;
            }
        }

        let project = render::project_from_path(&pane.current_path);
        let repo_full = render::basename(&pane.current_path).to_string();
        let short_target = render::short_target(&pane.session, &pane.window_index);

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
            pane: format!("{}/{}", pane.server, pane.pane_id),
            session_id: sess.session_id.clone(),
            cwd: sess.cwd.clone(),
            status: sess.status.clone(),
            mode,
            plan_slug,
            ask: asking.get(&sess.session_id).cloned(),
            started_at: sess.started_at.map(|ms| ms / 1000),
            server: pane.server.clone(),
            tmux_session: pane.session.clone(),
            window_id: pane.window_id.clone(),
            pid: cpid,
            attached: pane.attached,
            account: account::of_pid(&proc_root, cpid, &home, &accounts),
            parked: false,
        });
    }
    (agents, gaps)
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
            short_target: render::short_target(&p.session, &window),
            project: render::project_from_path(&p.cwd),
            repo_full: render::basename(&p.cwd).to_string(),
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

fn map_file_path() -> PathBuf {
    std::env::temp_dir().join(format!("agent-panel-{}.map", std::process::id()))
}

/// Interactive chooser: render rows, drive fzf, jump to the selection. `query` is typed into
/// the search box up front.
pub fn run_interactive(query: Option<&str>) -> Result<()> {
    let agents = collect();
    if agents.is_empty() {
        println!("No claude agents running");
        // Launched in its own terminal (the pin, a popup), the window closes the moment
        // we exit, so the message would never be read. Hold it until a key.
        if std::io::stdin().is_terminal() {
            println!("(press enter)");
            let _ = std::io::stdin().read_line(&mut String::new());
        }
        return Ok(());
    }

    refresh_index();
    let map_file = map_file_path();
    let rows = write_rows(&agents, &map_file, saved_sort())?;
    // fzf runs --disabled (the panel matches, `search`), so a query typed up front is applied here.
    let rows_text = match query.filter(|q| !q.trim().is_empty()) {
        Some(q) => search::filter(&fs::read_to_string(search::notes_path(&map_file))?, q, &search::read_topics()),
        None => rows_text(&rows),
    };
    // Position the cursor on the currently active agent, if it is listed.
    let restore_line = tmux::current_target().and_then(|cur| {
        rows_text
            .lines()
            .position(|l| l.split('\t').next() == Some(cur.as_str()))
            .map(|i| i + 1) // fzf pos() is 1-based
    });

    let selected = fzf::run(&rows_text, &map_file, restore_line, query);
    let _ = fs::remove_file(&map_file);
    let _ = fs::remove_file(search::notes_path(&map_file));
    let selected = selected?;

    if let Some(line) = selected {
        // Header rows carry the heavy bar and an empty target — ignore them.
        if line.contains("━━") {
            return Ok(());
        }
        let target = line.split('\t').next().unwrap_or("");
        if !target.is_empty() {
            tmux::jump(target);
        }
    }
    Ok(())
}

/// ctrl-n: a new Claude in a fresh worktree of the repo the row's agent works in. `wt new
/// --claude` is the one new-agent verb (Prefix+p c and Prefix+f ctrl-n call it too); wt maps a
/// worktree path back to its main repo. A project header row has no target and starts nothing.
pub fn run_new_agent(target: &str) -> Result<()> {
    let Some(agent) = collect().into_iter().find(|a| a.target == target) else {
        bail!("no agent at {target:?}");
    };
    let status = std::process::Command::new("wt")
        .args(["new", "--claude", "-c", &agent.cwd])
        .stdout(std::process::Stdio::null())
        .status()
        .context("cannot run wt")?;
    if !status.success() {
        bail!("wt new --claude -c {} failed", agent.cwd);
    }
    Ok(())
}

/// Start an incremental `sessions index` in the background, detached so closing the panel does
/// not kill it, the way `sessions search` does: the titles a session took since the last refresh
/// are searchable from the next open. Only when an index exists; the first build is sessions'.
/// Where `setsid` is missing (macOS) nothing starts and search reads the index as it stands.
fn refresh_index() {
    if search::index_path().is_some_and(|p| p.exists()) {
        let _ = std::process::Command::new("setsid")
            .args(["-f", "sessions", "index"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

/// Render the rows in `sort` and write the preview map file they need, and the search notes
/// beside it (`search::notes`).
fn write_rows(agents: &[Agent], map_file: &Path, sort: sort::Sort) -> Result<Vec<render::Row>> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (rows, map_lines) = render::build(agents, sort, now);
    write_whole(map_file, &map_lines.join("\n"))?;
    // A missing index leaves each note to its row text: search still works on what is shown.
    let index = search::index_path().and_then(|p| fs::read_to_string(p).ok()).unwrap_or_default();
    write_whole(&search::notes_path(map_file), &search::notes(&rows, agents, &search::index_notes(&index)))?;
    Ok(rows)
}

/// Write by rename, so a `match` or preview callback reading the file while a reload rewrites
/// it sees the old file or the new one, never a truncated one.
fn write_whole(path: &Path, text: &str) -> Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

fn rows_text(rows: &[render::Row]) -> String {
    rows.iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// fzf `reload` callback: print fresh rows and rewrite the map file, so a label change made
/// from a key shows without leaving the chooser. `asking` keeps only the sessions waiting on
/// the human (ctrl-y). `step` is a C-o or A-o press: it moves the saved sort first.
///
/// `query` is the search box: the rows are filtered by it (`search::filter`), so a reload keeps
/// what was typed.
pub fn run_rows(map_file: &Path, asking: bool, step: Option<sort::Step>, query: &str) -> Result<()> {
    let mut sort = saved_sort();
    if let Some(step) = step {
        sort = sort.step(step);
        if let Some(file) = sort::state_file() {
            sort::save(&file, sort)?;
        }
    }
    write_rows(&only_asking(collect(), asking), map_file, sort)?;
    print_matches(&fs::read_to_string(search::notes_path(map_file))?, query);
    Ok(())
}

/// fzf `change` callback: the saved rows that match `query`, read from the notes `rows` wrote.
/// No tmux or transcript reads, so it keeps up with typing. Notes that cannot be read are
/// rebuilt, slower, rather than read as no agents.
pub fn run_match(map_file: &Path, query: &str) -> Result<()> {
    match fs::read_to_string(search::notes_path(map_file)) {
        Ok(notes) => {
            print_matches(&notes, query);
            Ok(())
        }
        Err(_) => run_rows(map_file, false, None, query),
    }
}

fn print_matches(notes: &str, query: &str) {
    let rows = search::filter(notes, query, &search::read_topics());
    // No match prints nothing: a blank line would be an empty, selectable row in fzf.
    if !rows.is_empty() {
        println!("{rows}");
    }
}

/// The sort the panel was last left in (`sort::state_file`), project when none.
fn saved_sort() -> sort::Sort {
    sort::state_file().map(|f| sort::load(&f)).unwrap_or_default()
}

/// The agents ctrl-y shows: all of them, or with `asking` only those that need the human.
fn only_asking(agents: Vec<Agent>, asking: bool) -> Vec<Agent> {
    agents.into_iter().filter(|a| !asking || a.needs_attention()).collect()
}

/// Jump to one `<server>/<session>:<window>` target, for surfaces that list agents
/// themselves (fleet.sh) and should not re-implement the cross-server hop.
pub fn run_jump(target: &str) -> Result<()> {
    tmux::jump(target);
    Ok(())
}

/// Plain TSV of every live agent: `target \t glyph \t project \t summary`, where
/// target is `<server>/<session>:<window>`.
///
/// Exists so other surfaces (fleet.sh in the cockpit) can reuse the pane x
/// `~/.claude/sessions` join instead of reimplementing it in bash and drifting.
/// Deliberately raw fields, not the chooser's display text: that carries box-drawing
/// header rows and alignment padding meant only for fzf.
///
/// `json` prints one object per line instead, with the session and transcript facts
/// fleet-sessions buckets on (status, cwd, plan mode, context size, plan file, the last
/// entry's time as `idle_since`, the process start as `started_at`, and `edited_files`), and
/// what an action on the session needs (server, tmux session, window id, claude pid, account,
/// attached, parked, plan slug, ask id). `parked` adds the parked rows (`collect_all`).
///
/// A read with gaps still prints the rows it has, then names each gap on stderr and exits 3:
/// a partial list must not pass for a whole one to a caller that reads a missing session as
/// gone (fleet-dispatch reap, ar-916).
pub fn run_list(json: bool, parked: bool, needs: bool) -> Result<()> {
    let (agents, gaps) = if parked { collect_all_read() } else { collect_read() };
    for a in agents {
        if !json {
            print!("{}\t{}\t{}\t{}", a.target, a.glyph, a.project, a.summary);
            if needs {
                print!("\t{}", u8::from(a.needs_attention()));
            }
            println!();
            continue;
        }
        let (info, mtime) = match &a.jsonl {
            Some(p) => (
                jsonl::fleet_info(p),
                fs::metadata(p)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0, |d| d.as_secs()),
            ),
            None => (jsonl::fleet_info(Path::new("")), 0),
        };
        let idle_since = idle_since(info.last_entry, mtime, a.started_at);
        let row = serde_json::json!({
            "target": a.target,
            "pane": a.pane,
            "status": a.status,
            "project": a.project,
            "cwd": a.cwd,
            "session_id": a.session_id,
            "transcript": a.jsonl.as_ref().map(|p| p.to_string_lossy()).unwrap_or_default(),
            "plan_mode": a.mode == jsonl::Mode::Plan,
            "idle_since": idle_since,
            "started_at": a.started_at,
            "context_tokens": info.context_tokens,
            "model": info.model,
            "plan_file": info.plan_file,
            "edited_files": info.edited_files,
            "summary": a.summary,
            "time_use": info.time_use,
            "open_job": info.open_job,
            "doing": info.doing,
            "said": info.said,
            "compactions": info.compactions,
            "server": a.server,
            "tmux_session": a.tmux_session,
            "window_id": a.window_id,
            "pid": a.pid,
            "account": a.account,
            "attached": a.attached,
            "parked": a.parked,
            "plan": a.plan_slug,
            "ask": a.ask,
        });
        println!("{row}");
    }
    if gaps.is_empty() {
        return Ok(());
    }
    let _ = std::io::Write::flush(&mut std::io::stdout()); // a reader gone (EPIPE) still gets the 3
    for g in &gaps {
        eprintln!("agent-panel: incomplete read: {g}");
    }
    std::process::exit(3)
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

/// Prefix G: jump to the next agent that needs the human, after the current one. With none, it
/// says so in the message bar and stays put; jumping somewhere else would read as "this one".
pub fn run_next() -> Result<()> {
    let agents = collect();
    let current = tmux::current_target();
    match next_needing(&agents, current.as_deref()) {
        Next::Jump(target) => tmux::jump(target),
        Next::OnlyHere => tmux::message("only this session needs you"),
        Next::Nobody => tmux::message("no session needs you"),
    }
    Ok(())
}

#[derive(Debug, PartialEq)]
enum Next<'a> {
    Jump(&'a str),
    OnlyHere,
    Nobody,
}

/// The first agent needing attention after `current` in list order, wrapping around.
fn next_needing<'a>(agents: &'a [Agent], current: Option<&str>) -> Next<'a> {
    let start = current
        .and_then(|c| agents.iter().position(|a| a.target == c))
        .map_or(0, |i| i + 1);
    let n = agents.len();
    let hit = (0..n)
        .map(|k| &agents[(start + k) % n])
        .find(|a| a.needs_attention());
    match hit {
        None => Next::Nobody,
        Some(a) if Some(a.target.as_str()) == current => Next::OnlyHere,
        Some(a) => Next::Jump(&a.target),
    }
}

/// fzf preview callback: render the pane state + recent events for one row.
pub fn run_preview(map_file: &Path, row: &str) -> Result<()> {
    if row.contains("━━") {
        return Ok(()); // header row, no preview
    }
    let mut target = row.split('\t').next().unwrap_or("").to_string();
    // Fallback: dig a [server/]session:window token out of the visible text.
    if !target.contains(':') {
        target = extract_target(row).unwrap_or_default();
    }
    if target.is_empty() {
        return Ok(());
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    render::preview(&target, &lookup(map_file, &target), now);
    Ok(())
}

/// Find a `[server/]session:window` token in arbitrary row text.
fn extract_target(row: &str) -> Option<String> {
    for tok in row.split_whitespace() {
        if let Some((a, b)) = tok.split_once(':') {
            if !a.is_empty()
                && a.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-' || c == '/')
                && !b.is_empty()
                && b.chars().all(|c| c.is_ascii_digit())
            {
                return Some(tok.to_string());
            }
        }
    }
    None
}

/// Read the preview map file for a target row:
/// `target \t project \t summary \t repo_full \t ask ...` (`render::Facts::line`).
/// The preview facts the map file holds for `target`; empty when it holds none.
fn lookup(map_file: &Path, target: &str) -> render::Facts {
    fs::read_to_string(map_file)
        .ok()
        .and_then(|text| text.lines().map(render::Facts::parse).find(|(t, _)| t == target))
        .map(|(_, f)| f)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_since_prefers_the_entry_then_the_mtime_then_the_process_start() {
        assert_eq!(idle_since(Some(30), 20, Some(10)), 30);
        assert_eq!(idle_since(None, 20, Some(10)), 20);
        assert_eq!(idle_since(None, 0, Some(10)), 10);
        assert_eq!(idle_since(None, 0, None), 0);
    }

    #[test]
    fn extracts_target_token() {
        assert_eq!(
            extract_target(" ✓ agent-2:1 some summary"),
            Some("agent-2:1".to_string())
        );
        assert_eq!(
            extract_target(" ~ lab/platform-agent-5:2 summary"),
            Some("lab/platform-agent-5:2".to_string())
        );
        assert_eq!(extract_target("no target here"), None);
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
        let plan_dialog = Agent { glyph: '!', mode: jsonl::Mode::Plan, ..live_agent("hub", "a", false) };
        let plan_idle = Agent { glyph: '✓', mode: jsonl::Mode::Plan, ..live_agent("hub", "a", false) };
        let plan_busy = Agent { glyph: '~', mode: jsonl::Mode::Plan, ..live_agent("hub", "b", false) };
        assert!(plan_dialog.needs_attention());
        assert!(!plan_idle.needs_attention());
        assert!(!plan_busy.needs_attention());
    }

    #[test]
    fn prefix_g_jumps_only_to_what_needs_you() {
        let quiet = |s| Agent { glyph: '✓', ..live_agent("hub", s, false) };
        let prompt = |s| Agent { glyph: '!', ..live_agent("hub", s, false) };
        // Nothing needs you: no jump, with or without a current window.
        let none = vec![quiet("a"), quiet("b")];
        assert_eq!(next_needing(&none, Some("hub/a:1")), Next::Nobody);
        assert_eq!(next_needing(&none, None), Next::Nobody);
        assert_eq!(next_needing(&[], None), Next::Nobody);
        // The next one after the current, wrapping past the end.
        let agents = vec![prompt("a"), quiet("b"), prompt("c")];
        assert_eq!(next_needing(&agents, Some("hub/a:1")), Next::Jump("hub/c:1"));
        assert_eq!(next_needing(&agents, Some("hub/c:1")), Next::Jump("hub/a:1"));
        assert_eq!(next_needing(&agents, None), Next::Jump("hub/a:1"));
        // Only the current one: say so instead of jumping to itself.
        let solo = vec![prompt("a"), quiet("b")];
        assert_eq!(next_needing(&solo, Some("hub/a:1")), Next::OnlyHere);
    }

    #[test]
    fn ctrl_y_keeps_only_the_sessions_waiting_on_the_human() {
        let prompt = Agent { glyph: '!', ..live_agent("hub", "a", false) };
        let busy = Agent { glyph: '~', ..live_agent("hub", "b", false) };
        let pending = Agent { ask: Some("x1".into()), ..live_agent("hub", "c", false) };
        let agents = vec![pending, busy, prompt];
        let kept: Vec<_> = only_asking(agents.clone(), true).into_iter().map(|a| a.target).collect();
        assert_eq!(kept, ["hub/c:1", "hub/a:1"]);
        // Off: every agent, in order.
        assert_eq!(only_asking(agents, false).len(), 3);
    }

    #[test]
    fn the_preview_map_carries_the_ask_id() {
        let dir = std::env::temp_dir().join(format!("agent-panel-map-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let map = dir.join("map");
        fs::write(&map, "hub/a:1\tdotfiles\tsum\tdotfiles-x\tJSVBgC\nhub/b:1\tnotes\t\t\t\n").unwrap();
        assert_eq!(lookup(&map, "hub/a:1").ask, "JSVBgC");
        assert_eq!(lookup(&map, "hub/b:1").ask, "");
        assert_eq!(lookup(&map, "hub/none:1").ask, "");
        fs::remove_dir_all(&dir).unwrap();
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
}
