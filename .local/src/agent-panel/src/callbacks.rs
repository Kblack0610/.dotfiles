//! The callbacks the open chooser runs through `agent-panel <verb>`, wired in `fzf::args`:
//! `rows` (reload), `match` (change), `move` (the S-Tab grab), `preview` and `new-agent`
//! (ctrl-n). `write_rows` writes the map and notes files they share: `rows` and a grab rewrite
//! them, while `match`, a held step and `preview` read them and no session.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};

use agent_core::agent::{self, collect, Agent};

use crate::{dispatched, fzf, render, search, sort};

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

/// Render the rows in `sort`, in the saved A-d view (`dispatched`), and write the preview map file
/// they need, and the search notes beside it (`search::notes`).
pub(crate) fn write_rows(
    agents: Vec<Agent>,
    map_file: &Path,
    sort: sort::Sort,
) -> Result<Vec<render::Row>> {
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
    let mut sort = sort::saved();
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
    let saved = sort::saved();
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

/// The agents ctrl-y shows: all of them, or with `asking` only those that need the human.
fn only_asking(agents: Vec<Agent>, asking: bool) -> Vec<Agent> {
    agents
        .into_iter()
        .filter(|a| !asking || a.needs_attention())
        .collect()
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
    fn ctrl_y_keeps_only_the_sessions_waiting_on_the_human() {
        let prompt = Agent {
            glyph: '!',
            target: "hub/a:1".into(),
            ..Agent::default()
        };
        let busy = Agent {
            glyph: '~',
            target: "hub/b:1".into(),
            ..Agent::default()
        };
        let pending = Agent {
            ask: Some("x1".into()),
            target: "hub/c:1".into(),
            ..Agent::default()
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
