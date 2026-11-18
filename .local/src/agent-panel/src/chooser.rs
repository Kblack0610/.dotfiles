//! Orchestration for the three entry points: interactive chooser, `next`, and
//! the internal `preview` callback. The agents themselves come from `agent_core::agent`.

use std::collections::HashSet;
use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

use agent_core::agent::{self, collect, collect_read, Agent, Gaps};
use agent_core::{asks, tmux};

use crate::{dispatched, fzf, render, search, sort};

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
    let rows = write_rows(agents, &map_file, saved_sort())?;
    // fzf runs --disabled (the panel matches, `search`), so a query typed up front is applied here.
    let rows_text = match query.filter(|q| !q.trim().is_empty()) {
        Some(q) => search::filter(
            &fs::read_to_string(search::notes_path(&map_file))?,
            q,
            &search::read_topics(),
        ),
        None => rows_text(&rows),
    };
    // Position the cursor on the currently active agent, if it is listed.
    let restore_line = tmux::current_target().and_then(|cur| {
        rows_text
            .lines()
            .position(|l| l.split('\t').next() == Some(cur.as_str()))
            .map(|i| i + 1) // fzf pos() is 1-based
    });

    let selected = fzf::run(
        &rows_text,
        &map_file,
        restore_line,
        query,
        dispatched::saved().label(),
    );
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

/// Render the rows in `sort`, in the saved A-d view (`dispatched`), and write the preview map file
/// they need, and the search notes beside it (`search::notes`).
fn write_rows(agents: Vec<Agent>, map_file: &Path, sort: sort::Sort) -> Result<Vec<render::Row>> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut agents = dispatched::saved().filter(agents);
    agent::with_last_active(&mut agents);
    let agents = &agents[..];
    let (rows, map_lines) = render::build(agents, sort, now);
    write_whole(map_file, &map_lines.join("\n"))?;
    // A missing index leaves each note to its row text: search still works on what is shown.
    let index = search::index_path()
        .and_then(|p| fs::read_to_string(p).ok())
        .unwrap_or_default();
    write_whole(
        &search::notes_path(map_file),
        &search::notes(&rows, agents, &search::index_notes(&index)),
    )?;
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
/// the human (ctrl-y); `write_rows` applies the A-d view. `step` is a C-o or A-o press: it
/// moves the saved sort first.
///
/// `query` is the search box: the rows are filtered by it (`search::filter`), so a reload keeps
/// what was typed.
pub fn run_rows(
    map_file: &Path,
    asking: bool,
    step: Option<sort::Step>,
    query: &str,
) -> Result<()> {
    let mut sort = saved_sort();
    if let Some(step) = step {
        sort = sort.step(step);
        if let Some(file) = sort::state_file() {
            sort::save(&file, sort)?;
        }
    }
    write_rows(only_asking(collect(), asking), map_file, sort)?;
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

/// A key the S-Tab grab changes, read by `agent-panel move`: what it does depends on whether a
/// row is held, which the prompt says (`fzf::PROMPT_MOVING`), the way ctrl-y's view lives in
/// the prompt too.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum MoveKey {
    /// S-Tab: grab the row, or drop the one held.
    Grab,
    Up,
    Down,
    /// Enter: drop the held row, else jump.
    Accept,
    /// Esc: drop the held row, else close.
    Abort,
}

/// fzf `transform` callback for the keys a grab changes: prints the actions to run. Holding a
/// row, Up and Down swap it with its neighbour in the custom order (saved, then the rows
/// rewritten), and the cursor follows it by `pos`, after a `reload-sync` so it lands on the new
/// list. A grab out of another sort starts the custom order from the rows as shown.
pub fn run_move(key: MoveKey, target: &str, map_file: &Path) -> Result<()> {
    let moving = std::env::var("FZF_PROMPT").is_ok_and(|p| p.starts_with(fzf::PROMPT_MOVING));
    let query = std::env::var("FZF_QUERY").unwrap_or_default();
    let step = match (key, moving) {
        (MoveKey::Grab | MoveKey::Accept | MoveKey::Abort, true) => {
            return say(&format!(
                "change-prompt({})+rebind({})",
                fzf::PROMPT_ALL,
                fzf::KEYS_OFF_WHILE_MOVING
            ))
        }
        (MoveKey::Up, false) => return say(fzf::UP_SKIPPING_HEADERS),
        (MoveKey::Down, false) => return say(fzf::DOWN_SKIPPING_HEADERS),
        (MoveKey::Accept, false) => return say("accept"),
        (MoveKey::Abort, false) => return say("abort"),
        (MoveKey::Grab, false) if target.is_empty() => return Ok(()), // a header row
        (MoveKey::Grab, false) => 0,
        (MoveKey::Up, true) => -1,
        (MoveKey::Down, true) => 1,
    };
    let custom = sort::Sort {
        key: sort::Key::Custom,
        reverse: false,
    };
    let order_file = sort::order_file().context("no HOME for the panel's state")?;
    let notes_file = search::notes_path(map_file);
    // The rows on screen, as the last reload wrote them: what is moved, and among which rows.
    let notes = fs::read_to_string(&notes_file)?;
    let topics = search::read_topics();
    let shown: Vec<&str> = notes.lines().filter_map(note_target).collect();
    let visible = search::filter(&notes, &query, &topics);
    let neighbour = next_to(&visible, target, step);
    let saved = saved_sort();
    let mut order = if saved == custom {
        sort::load_order(&order_file)
    } else {
        Vec::new() // leaving another sort: your order starts as the rows are shown
    };
    for t in &shown {
        if !order.iter().any(|o| o == t) {
            order.push(t.to_string());
        }
    }
    if let Some(n) = neighbour {
        swap_with(&mut order, target, n);
    }
    let notes = if step == 0 || saved != custom {
        // A grab: read every session once, drop gone ones from the order, and show them all
        // in your order (this leaves the asking-only view, but keeps the A-d one: a hidden
        // row keeps its place in the order).
        let agents = collect();
        order.retain(|t| agents.iter().any(|a| &a.target == t));
        sort::save_order(&order_file, &order)?;
        if saved != custom {
            if let Some(file) = sort::state_file() {
                sort::save(&file, custom)?;
            }
        }
        write_rows(agents, map_file, custom)?;
        fs::read_to_string(&notes_file)?
    } else {
        // A step: the rows already on screen, two of them swapped. No session is read again.
        let Some(n) = neighbour else {
            return Ok(()); // at either end of the shown rows
        };
        sort::save_order(&order_file, &order)?;
        let swapped = swap_lines(&notes, target, n);
        write_whole(&notes_file, &swapped)?;
        swapped
    };
    let pos = search::filter(&notes, &query, &topics)
        .lines()
        .position(|l| l.split('\t').next() == Some(target))
        .map_or(1, |i| i + 1);
    let exe = std::env::current_exe()?.to_string_lossy().into_owned();
    let reload = format!(
        "reload-sync({exe} match --map-file '{}' --query={{q}})+pos({pos})",
        map_file.display()
    );
    if key == MoveKey::Grab {
        say(&format!(
            "change-prompt({}{} > )+unbind({})+{reload}",
            fzf::PROMPT_MOVING,
            target.replace([')', '('], ""),
            fzf::KEYS_OFF_WHILE_MOVING
        ))
    } else {
        say(&reload)
    }
}

fn say(actions: &str) -> Result<()> {
    println!("{actions}");
    Ok(())
}

/// A notes line's target (`search::notes`: `note \t target \t ...`); none for a header.
fn note_target(line: &str) -> Option<&str> {
    let (_, row) = line.split_once('\t')?;
    row.split('\t').next().filter(|t| !t.is_empty())
}

/// The row `step` places from `target` among the `visible` rows (`search::filter` output); none
/// at either end, for a grab (0), or when `target` is not shown.
fn next_to<'a>(visible: &'a str, target: &str, step: i32) -> Option<&'a str> {
    let rows: Vec<&str> = visible
        .lines()
        .filter_map(|l| l.split('\t').next().filter(|t| !t.is_empty()))
        .collect();
    let i = rows.iter().position(|t| *t == target)? as i64 + step as i64;
    (step != 0 && i >= 0)
        .then(|| rows.get(i as usize).copied())
        .flatten()
}

/// Swap `a` and `b` in `order`; rows between them (hidden by a search) keep their places.
fn swap_with(order: &mut [String], a: &str, b: &str) {
    let i = order.iter().position(|t| t == a);
    let j = order.iter().position(|t| t == b);
    if let (Some(i), Some(j)) = (i, j) {
        order.swap(i, j);
    }
}

/// The notes with the lines of targets `a` and `b` swapped, the same swap `swap_with` made.
fn swap_lines(notes: &str, a: &str, b: &str) -> String {
    let mut lines: Vec<&str> = notes.lines().collect();
    let i = lines.iter().position(|l| note_target(l) == Some(a));
    let j = lines.iter().position(|l| note_target(l) == Some(b));
    if let (Some(i), Some(j)) = (i, j) {
        lines.swap(i, j);
    }
    lines.join("\n")
}

/// The sort the panel was last left in (`sort::state_file`), project when none.
pub fn saved_sort() -> sort::Sort {
    sort::state_file()
        .map(|f| sort::load(&f))
        .unwrap_or_default()
}

/// The agents ctrl-y shows: all of them, or with `asking` only those that need the human.
fn only_asking(agents: Vec<Agent>, asking: bool) -> Vec<Agent> {
    agents
        .into_iter()
        .filter(|a| !asking || a.needs_attention())
        .collect()
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
/// `json` prints one `agent_core::agent::ListRow` per line instead: the session and transcript
/// facts fleet-sessions buckets on and what an action on the session needs. `parked` adds the
/// parked rows (`collect_all`).
///
/// A read with gaps still prints the rows it has, then names each gap on stderr and exits 3:
/// a partial list must not pass for a whole one to a caller that reads a missing session as
/// gone (fleet-dispatch reap, ar-916).
pub fn run_list(json: bool, parked: bool, codex: bool) -> Result<()> {
    let (agents, gaps) = if parked {
        agent::collect_all_read()
    } else {
        collect_read()
    };
    let agents: Vec<Agent> = agents.into_iter().filter(|a| codex || !a.codex).collect();
    if !json {
        for a in &agents {
            println!("{}\t{}\t{}\t{}", a.target, a.glyph, a.project, a.summary);
        }
        return exit_on_gaps(&gaps);
    }
    for row in agent::list_rows(&agents) {
        println!("{}", serde_json::to_string(&row)?);
    }
    exit_on_gaps(&gaps)
}

/// A read with gaps names each on stderr and exits 3, after the rows it could print.
fn exit_on_gaps(gaps: &Gaps) -> Result<()> {
    if gaps.is_empty() {
        return Ok(());
    }
    let _ = std::io::Write::flush(&mut std::io::stdout()); // a reader gone (EPIPE) still gets the 3
    for g in gaps {
        eprintln!("agent-panel: incomplete read: {g}");
    }
    std::process::exit(3)
}

/// Prefix G: jump to the next agent that needs the human, after the current one. With none, it
/// says so in the message bar and stays put; jumping somewhere else would read as "this one".
/// Asks no live session owns have nowhere to jump to, so the message counts them.
pub fn run_next() -> Result<()> {
    let (agents, gaps) = collect_read();
    let current = tmux::current_target();
    // A partial read could take a live owner for a gone one, so it counts nothing (ar-916).
    let orphans = || {
        let live: HashSet<&str> = agents.iter().map(|a| a.session_id.as_str()).collect();
        gaps.is_empty()
            .then(|| asks::without_live_owner(&asks::root(), &live))
    };
    match next_needing(&agents, current.as_deref()) {
        Next::Jump(target) => tmux::jump(target),
        Next::OnlyHere => tmux::message(&with_orphans("only this session needs you", orphans())),
        Next::Nobody => tmux::message(&with_orphans("no session needs you", orphans())),
    }
    Ok(())
}

/// `base`, plus how many asks wait in Prefix y with no live session to jump to.
fn with_orphans(base: &str, orphans: Option<usize>) -> String {
    match orphans {
        Some(1) => format!("{base}; 1 ask with no live session in Prefix y"),
        Some(n) if n > 1 => format!("{base}; {n} asks with no live session in Prefix y"),
        _ => base.to_string(),
    }
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
                && a.chars()
                    .all(|c| c.is_alphanumeric() || c == '_' || c == '-' || c == '/')
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
        .and_then(|text| {
            text.lines()
                .map(render::Facts::parse)
                .find(|(t, _)| t == target)
        })
        .map(|(_, f)| f)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
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
    fn a_step_swaps_with_the_next_shown_row_and_skips_rows_a_search_hides() {
        let order = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        // A search shows a and c; b is hidden between them.
        let visible = "\t\tall\na\trow a\nc\trow c";
        assert_eq!(next_to(visible, "a", 1), Some("c"));
        assert_eq!(next_to(visible, "c", -1), Some("a"));
        let mut o = order(&["a", "b", "c"]);
        swap_with(&mut o, "a", "c");
        assert_eq!(o, order(&["c", "b", "a"]), "the hidden row keeps its place");
        // Negative control: the ends, a grab, and an unshown target have no neighbour.
        assert_eq!(next_to(visible, "a", -1), None);
        assert_eq!(next_to(visible, "c", 1), None);
        assert_eq!(next_to(visible, "a", 0), None);
        assert_eq!(next_to(visible, "b", 1), None);
    }

    #[test]
    fn swap_lines_swaps_two_rows_and_leaves_headers_and_the_rest() {
        let notes = "h\t\tall, your order\nna\ta\trow a\nnb\tb\trow b\nnc\tc\trow c";
        assert_eq!(
            swap_lines(notes, "a", "c"),
            "h\t\tall, your order\nnc\tc\trow c\nnb\tb\trow b\nna\ta\trow a"
        );
        assert_eq!(note_target("h\t\tall"), None, "a header has no target");
        assert_eq!(
            swap_lines(notes, "a", "zz"),
            notes,
            "an unknown row moves nothing"
        );
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

    #[test]
    fn prefix_g_jumps_only_to_what_needs_you() {
        let quiet = |s| Agent {
            glyph: '✓',
            ..live_agent("hub", s, false)
        };
        let prompt = |s| Agent {
            glyph: '!',
            ..live_agent("hub", s, false)
        };
        // Nothing needs you: no jump, with or without a current window.
        let none = vec![quiet("a"), quiet("b")];
        assert_eq!(next_needing(&none, Some("hub/a:1")), Next::Nobody);
        assert_eq!(next_needing(&none, None), Next::Nobody);
        assert_eq!(next_needing(&[], None), Next::Nobody);
        // The next one after the current, wrapping past the end.
        let agents = vec![prompt("a"), quiet("b"), prompt("c")];
        assert_eq!(
            next_needing(&agents, Some("hub/a:1")),
            Next::Jump("hub/c:1")
        );
        assert_eq!(
            next_needing(&agents, Some("hub/c:1")),
            Next::Jump("hub/a:1")
        );
        assert_eq!(next_needing(&agents, None), Next::Jump("hub/a:1"));
        // Only the current one: say so instead of jumping to itself.
        let solo = vec![prompt("a"), quiet("b")];
        assert_eq!(next_needing(&solo, Some("hub/a:1")), Next::OnlyHere);
    }

    #[test]
    fn prefix_g_counts_the_asks_it_cannot_jump_to() {
        assert_eq!(
            with_orphans("no session needs you", Some(0)),
            "no session needs you"
        );
        assert_eq!(
            with_orphans("no session needs you", None),
            "no session needs you",
            "a partial read claims nothing"
        );
        assert_eq!(
            with_orphans("no session needs you", Some(1)),
            "no session needs you; 1 ask with no live session in Prefix y"
        );
        assert_eq!(
            with_orphans("only this session needs you", Some(26)),
            "only this session needs you; 26 asks with no live session in Prefix y"
        );
    }

    #[test]
    fn ctrl_y_keeps_only_the_sessions_waiting_on_the_human() {
        let prompt = Agent {
            glyph: '!',
            ..live_agent("hub", "a", false)
        };
        let busy = Agent {
            glyph: '~',
            ..live_agent("hub", "b", false)
        };
        let pending = Agent {
            ask: Some("x1".into()),
            ..live_agent("hub", "c", false)
        };
        let agents = vec![pending, busy, prompt];
        let kept: Vec<_> = only_asking(agents.clone(), true)
            .into_iter()
            .map(|a| a.target)
            .collect();
        assert_eq!(kept, ["hub/c:1", "hub/a:1"]);
        // Off: every agent, in order.
        assert_eq!(only_asking(agents, false).len(), 3);
    }

    #[test]
    fn the_preview_map_carries_the_ask_id() {
        let dir = std::env::temp_dir().join(format!("agent-panel-map-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let map = dir.join("map");
        fs::write(
            &map,
            "hub/a:1\tdotfiles\tsum\tdotfiles-x\tJSVBgC\nhub/b:1\tnotes\t\t\t\n",
        )
        .unwrap();
        assert_eq!(lookup(&map, "hub/a:1").ask, "JSVBgC");
        assert_eq!(lookup(&map, "hub/b:1").ask, "");
        assert_eq!(lookup(&map, "hub/none:1").ask, "");
        fs::remove_dir_all(&dir).unwrap();
    }
}
