//! Orchestration for the three entry points: interactive chooser, `next`, and
//! the internal `preview` callback.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::{account, asks, fzf, jsonl, parked, procmap::ProcMap, render, session, tmux};

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
    /// In plan mode (Shift+Tab / EnterPlanMode), so it will not edit until a plan is approved.
    pub plan: bool,
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
    /// Waiting on the human: at a prompt or dialog (`!`), or holding a pending ask. A question
    /// asked only in the conversation is not a source: the Stop check makes the session file it.
    pub fn needs_attention(&self) -> bool {
        self.glyph == '!' || self.ask.is_some()
    }
}

/// Walk every tmux pane, keep those whose process tree contains a live Claude
/// session, and build an ordered agent list.
pub fn collect() -> Vec<Agent> {
    live(tmux::list_panes(), &asks::pending_sessions(&asks::root()))
}

fn live(panes: Vec<tmux::Pane>, asking: &HashMap<String, String>) -> Vec<Agent> {
    let Ok(procmap) = ProcMap::capture() else {
        return Vec::new();
    };
    let sessions = session::load_all();
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
        let (mut summary, plan, plan_slug) = if jsonl_path.exists() {
            let info = jsonl::row_info(&jsonl_path);
            (info.summary, info.plan, info.plan_slug)
        } else {
            (String::new(), false, String::new())
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
            plan,
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
    agents
}

/// The live agents plus a row per parked session, the human's own session first: what a
/// view that acts on sessions lists (agent-web, `list --json --parked`).
pub fn collect_all() -> Vec<Agent> {
    let panes = tmux::list_panes();
    let attached: HashSet<(String, String)> = panes
        .iter()
        .filter(|p| p.attached)
        .map(|p| (p.server.clone(), p.session.clone()))
        .collect();
    let asking = asks::pending_sessions(&asks::root());
    let agents = live(panes, &asking);
    let rows = parked::load(&parked::root());
    let mut all = with_parked(agents, rows, &attached, &asking, &account::load());
    attached_first(&mut all);
    all
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

/// Interactive chooser: render rows, drive fzf, jump to the selection.
pub fn run_interactive() -> Result<()> {
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

    let map_file = map_file_path();
    let rows = write_rows(&agents, &map_file)?;
    let rows_text = rows_text(&rows);

    // Position the cursor on the currently active agent, if any.
    let restore_line = tmux::current_target().and_then(|cur| {
        rows.iter()
            .position(|r| r.target == cur)
            .map(|i| i + 1) // fzf pos() is 1-based
    });

    let selected = fzf::run(&rows_text, &map_file, restore_line);
    let _ = fs::remove_file(&map_file);
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

/// The agent whose ask to show a client that just arrived at `server/session:window`: the one in
/// that window, else any in the same tmux session, and only one that holds a pending ask.
pub fn ask_here<'a>(agents: &'a [Agent], server: &str, session: &str, window: &str) -> Option<&'a Agent> {
    let here = tmux::qualify(server, session, window);
    agents
        .iter()
        .filter(|a| a.ask.is_some() && a.server == server && a.tmux_session == session)
        .min_by_key(|a| a.target != here)
}

/// `ask-here`: the tmux arrival hook runs it with `key` false, and a session that is asking
/// something gets a status-line notice on that client, never a popup: the human is working and
/// their next keystroke belongs to the pane. Prefix y runs it with `key` true and opens the list
/// of every pending ask in a popup, to answer them one after another.
pub fn run_ask_here(socket: &str, client: &str, session: &str, window: &str, key: bool) -> Result<()> {
    if key {
        let cmd = vec![asks::agent_ask_path().to_string_lossy().into_owned(), "pick".to_string()];
        tmux::popup(socket, client, " questions ", &cmd);
        return Ok(());
    }
    let server = Path::new(socket)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let agents = collect();
    if let Some(id) = ask_here(&agents, &server, session, window).and_then(|a| a.ask.clone()) {
        tmux::notice(socket, client, &notice_text(&asks::question(&id)));
    }
    Ok(())
}

/// The status-line notice for a session asking `question`: the question, cut to fit, and the key.
pub fn notice_text(question: &str) -> String {
    const MAX: usize = 90;
    let q: String = if question.chars().count() > MAX {
        question.chars().take(MAX - 3).collect::<String>() + "..."
    } else if question.is_empty() {
        "a question".to_string()
    } else {
        question.to_string()
    };
    // display-message expands #; a literal one is ##.
    format!("asking you: {} - Prefix y to answer", q.replace('#', "##"))
}

/// Render the rows and write the preview map file they need.
fn write_rows(agents: &[Agent], map_file: &Path) -> Result<Vec<render::Row>> {
    let (rows, map_lines) = render::build(agents);
    fs::write(map_file, map_lines.join("\n"))?;
    Ok(rows)
}

fn rows_text(rows: &[render::Row]) -> String {
    rows.iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// fzf `reload` callback: print fresh rows and rewrite the map file, so a label change made
/// from a key shows without leaving the chooser.
pub fn run_rows(map_file: &Path) -> Result<()> {
    println!("{}", rows_text(&write_rows(&collect(), map_file)?));
    Ok(())
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
pub fn run_list(json: bool, parked: bool) -> Result<()> {
    for a in if parked { collect_all() } else { collect() } {
        if !json {
            println!("{}\t{}\t{}\t{}", a.target, a.glyph, a.project, a.summary);
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
            "plan_mode": a.plan,
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
    Ok(())
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

/// Jump to the next agent needing attention (`!` or a pending ask), else the next in the list.
pub fn run_next() -> Result<()> {
    let agents = collect();
    if agents.is_empty() {
        return Ok(());
    }
    let current = tmux::current_target();
    let cur_idx = current
        .as_ref()
        .and_then(|c| agents.iter().position(|a| &a.target == c));
    let total = agents.len();
    let start = cur_idx.map(|i| i as isize).unwrap_or(-1);

    // First look for the next attention-needed agent after the current one.
    let mut target: Option<&str> = None;
    for step in 1..=total {
        let idx = (((start + step as isize) % total as isize + total as isize)
            % total as isize) as usize;
        if agents[idx].needs_attention() {
            target = Some(&agents[idx].target);
            break;
        }
    }
    // Otherwise just advance to the next agent.
    let next_target = target.unwrap_or_else(|| {
        let idx = (((start + 1) % total as isize + total as isize) % total as isize) as usize;
        &agents[idx].target
    });

    tmux::jump(next_target);
    Ok(())
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

    let (jsonl_path, project, summary, repo_full, ask) = lookup(map_file, &target);
    render::preview(
        &target,
        jsonl_path.as_deref(),
        &project,
        &summary,
        &repo_full,
        &ask,
    );
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
/// `target \t jsonl \t project \t summary \t repo_full \t ask`.
type MapRow = (Option<PathBuf>, String, String, String, String);
fn lookup(map_file: &Path, target: &str) -> MapRow {
    let Ok(text) = fs::read_to_string(map_file) else {
        return MapRow::default();
    };
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.first() == Some(&target) {
            let jsonl = f.get(1).filter(|s| !s.is_empty()).map(PathBuf::from);
            return (
                jsonl,
                f.get(2).unwrap_or(&"").to_string(),
                f.get(3).unwrap_or(&"").to_string(),
                f.get(4).unwrap_or(&"").to_string(),
                f.get(5).unwrap_or(&"").to_string(),
            );
        }
    }
    MapRow::default()
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

    fn asking(server: &str, sess: &str, window: &str, ask: Option<&str>) -> Agent {
        Agent {
            target: tmux::qualify(server, sess, window),
            server: server.into(),
            tmux_session: sess.into(),
            ask: ask.map(String::from),
            ..Agent::default()
        }
    }

    #[test]
    fn ask_here_prefers_the_window_the_client_is_on() {
        let agents = vec![
            asking("hub", "dotfiles", "2", Some("other")),
            asking("hub", "dotfiles", "5", Some("this")),
            asking("lab", "dotfiles", "5", Some("other-server")),
        ];
        let got = ask_here(&agents, "hub", "dotfiles", "5").and_then(|a| a.ask.as_deref());
        assert_eq!(got, Some("this"));
        // Another window of the same session that asks: still shown.
        let got = ask_here(&agents, "hub", "dotfiles", "9").and_then(|a| a.ask.as_deref());
        assert_eq!(got, Some("other"));
    }

    #[test]
    fn the_notice_is_the_question_cut_to_fit_and_the_key() {
        assert_eq!(notice_text("ship #910 now?"), "asking you: ship ##910 now? - Prefix y to answer");
        let long = notice_text(&"x".repeat(200));
        assert!(long.contains(&format!("{}...", "x".repeat(87))), "{long}");
        assert_eq!(notice_text(""), "asking you: a question - Prefix y to answer");
    }

    #[test]
    fn ask_here_is_nothing_for_a_session_that_asks_nothing() {
        let agents = vec![
            asking("hub", "dotfiles", "1", None),
            asking("hub", "notes", "1", Some("elsewhere")),
            asking("lab", "dotfiles", "1", Some("other-server")),
        ];
        assert!(ask_here(&agents, "hub", "dotfiles", "1").is_none());
    }

    #[test]
    fn the_preview_map_carries_the_ask_id() {
        let dir = std::env::temp_dir().join(format!("agent-panel-map-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let map = dir.join("map");
        fs::write(&map, "hub/a:1\t\tdotfiles\tsum\tdotfiles-x\tJSVBgC\nhub/b:1\t\tnotes\t\t\t\n").unwrap();
        assert_eq!(lookup(&map, "hub/a:1").4, "JSVBgC");
        assert_eq!(lookup(&map, "hub/b:1").4, "");
        assert_eq!(lookup(&map, "hub/none:1").4, "");
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
