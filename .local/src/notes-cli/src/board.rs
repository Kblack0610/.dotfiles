//! `notes board` - every project's open version: the queue and the agent sheets, one file each.
//!
//! WHY THIS IS A FILE AND NOT A SECTION
//!
//! The daily note is the human's FOCUS surface. Rendering the board into it was the
//! obvious move and is the wrong one: the note is what gets opened in nvim every morning,
//! and anything pasted above `## Focus` competes with the one list the human actually
//! maintains. `## Current Projects` already proved that — a static index copy that earned
//! its removal. So the board is a file the footer LINKS: visible in one click, never in
//! the way.
//!
//! WHY IT CANNOT DISAGREE WITH `notes ptask list`
//!
//! It reads each project's `## Tasks` through `project_tasks::current_rows_for_dir` - the same
//! sheet, the same heading resolution and the same open-task predicate that `notes ptask
//! list` uses. There is one list, rendered twice, rather than two
//! lists that drift. The two boards read two SHEETS through that one parser: the project's
//! own `README.md` and its `agent/README.md`. Neither filters the other, so no board can
//! hide a row from the list it belongs to.
//!
//! CROSS-PROFILE ON PURPOSE
//!
//! Every profile's projects land in one file. "I don't know where <that app> is" was a
//! real complaint: per-profile surfaces mean the work you are not currently looking at is
//! invisible, which is the failure mode a board exists to prevent.

use crate::agent_sheet::Lane;
use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::md;
use crate::project_sweep;
use crate::project_tasks;
use crate::sheet::{self, V};
use anyhow::{Context, Result};
use chrono::Local;
use std::fs;
use std::path::PathBuf;

/// THE board — one file, one address, the same for every org.
///
/// This used to derive from the profile's own `project_index`, which made a cross-org artifact
/// have a per-org address. Two things went wrong at once and neither was visible: `write()`
/// resolved the ACTIVE profile, so the aggregate landed wherever the current org happened to
/// point (personal, in practice) and `notes --profile bnb today` silently rewrote personal's
/// file; while `ensure_footer` used the PER-PROFILE address, so every non-active org's daily
/// note linked a `board.md` that had never been written there. Verified on disk: one board
/// existed, and bnb's note carried a dangling `Board: [[projects/board]]`.
///
/// Anchoring to the vault removes the disagreement by construction — there is no longer a
/// per-profile answer for the two sides to differ on.
pub fn board_path(p: &Profile) -> Option<PathBuf> {
    Some(p.board.clone())
}

/// The agent board, DERIVED as a sibling of the board rather than configured separately.
///
/// Same argument `board_path` makes above: one address, identical on every profile. A second
/// config key would be a second thing to get wrong, and two surfaces that disagree about
/// where the agent lane lives is exactly the bug that left orgs linking a board nobody wrote.
pub fn agent_board_path(p: &Profile) -> Option<PathBuf> {
    Some(p.board.with_file_name("agent-board.md"))
}

/// A project's name as a link to the SHEET the rows came from, so the board is a launchpad
/// and not just a readout: the whole point of seeing "14 open" is getting to the file where
/// you fill the next one in.
///
/// Vault-relative, like the daily note's footer link to the board, because the board is one
/// cross-org file at the vault root. A profile-root-relative target resolves only for
/// `personal` (whose root IS the vault) and dangles for every other org - the same class of
/// bug `board_path` above documents.
///
/// Falls back to the bare name when the vault cannot be resolved or the sheet is missing. An
/// unlinked heading is a cosmetic loss; a dangling wikilink is a broken promise.
fn linked_name(name: &str, dir: &std::path::Path) -> String {
    let Ok(p) = config::resolve(None) else {
        return name.to_string();
    };
    link_for(name, &p.vault, project_tasks::task_sheet(dir).as_deref())
}

/// The pure half of [`linked_name`]: vault + sheet -> the heading text.
///
/// Split out so the link rule is testable without a configured vault and without writing a
/// scratch project into the human's real notes to exercise it.
fn link_for(name: &str, vault: &std::path::Path, sheet: Option<&std::path::Path>) -> String {
    let Some(sheet) = sheet else {
        return name.to_string();
    };
    let target = config::wikilink(vault, sheet);
    // `wikilink` returns the path UNCHANGED when it is not under `vault`, so an absolute or
    // `..`-escaping target means "outside the vault" and must not become a link.
    if target.is_empty() || target.starts_with("..") || target.starts_with('/') {
        return name.to_string();
    }
    format!("[[{target}|{name}]]")
}

/// The open version's rows of `lane` for this project.
///
/// The lane names a DIRECTORY, so this is one parser pointed at one of two sheets rather
/// than one sheet split by a tag. A board can no longer hide a row from the human's own
/// list, which is what a filtered human lane did.
fn lane_tasks(dir: &std::path::Path, lane: Lane) -> Option<(String, Vec<String>)> {
    let w = project_tasks::current_rows_for_dir(&lane.dir(dir))?;
    Some((w.version, w.rows.into_iter().map(|r| r.text).collect()))
}

/// The one line the human board gives a project's playtest.md: how many checks wait, linked
/// to the file. Never the rows themselves: they are played from the file. `None` when no check
/// is open.
fn playtest_line(dir: &std::path::Path) -> Option<String> {
    let vault = config::resolve(None).ok()?.vault;
    playtest_line_for(dir, &vault)
}

/// The pure half of [`playtest_line`], linked by the same fail-closed rule as a heading.
fn playtest_line_for(dir: &std::path::Path, vault: &std::path::Path) -> Option<String> {
    let n = crate::playtest::open_count(dir);
    if n == 0 {
        return None;
    }
    let link = link_for("playtest.md", vault, Some(&crate::playtest::path(dir)));
    let s = if n == 1 { "" } else { "s" };
    Some(format!("- {n} playtest check{s} waiting -> {link}\n"))
}

/// The `N open` tail both renderers share, so the two counts cannot disagree. On the agent
/// lane, project `name` at `dir` in [`tiers`]'s words, read from its feed entry.
fn counts(open: &[String], lane: Lane, name: &str, dir: &std::path::Path) -> String {
    match lane {
        Lane::Human => format!("{} open", open.len()),
        Lane::Agent => feed_for_dir("", name, dir, chrono::Local::now().date_naive())
            .0
            .tiers(),
    }
}

/// `Sprint O/C | Today N | Backlog M | Epics E | Epic backlog B`, as every surface shows it: the
/// release windows' rows still open of the rows they hold ([`crate::window::Sprint`], left out
/// when no window is recorded), the agent board's rows and its Backlog tier, and the human
/// sheet's feature epics aimed at a release and not ([`crate::epics::strip_counts`]).
pub(crate) fn tiers(
    sprint: crate::window::Sprint,
    today: usize,
    backlog: usize,
    (epics, epic_backlog): (usize, usize),
) -> String {
    let head = if sprint.committed > 0 {
        format!("Sprint {}/{} | ", sprint.open, sprint.committed)
    } else {
        String::new()
    };
    format!("{head}Today {today} | Backlog {backlog} | Epics {epics} | Epic backlog {epic_backlog}")
}

/// The feed totals of `p`'s projects in [`tiers`]'s words: what `notes doctor` and each
/// profile's heading on `agent-board.md` show.
pub(crate) fn agent_tiers(p: &config::Profile) -> String {
    let today = chrono::Local::now().date_naive();
    let (mut projects, mut rows) = (Vec::new(), Vec::new());
    for (name, summary) in daily::discover_project_dirs(p) {
        let Some(dir) = summary.parent() else {
            continue;
        };
        let (proj, r) = feed_for_dir(&p.name, &name, dir, today);
        projects.push(proj);
        rows.extend(r);
    }
    Totals::of(&rows, &projects).tiers()
}

/// The rows a lane's board lists: all of the human lane's, the agent lane's minus its Backlog
/// tier, which the count beside them stands for.
fn listed(open: &[String], lane: Lane) -> impl Iterator<Item = &String> {
    open.iter()
        .filter(move |l| lane == Lane::Human || !project_sweep::in_backlog(l))
}

/// One project's rendered block, or `None` when it has no task sheet.
fn project_block(name: &str, dir: &std::path::Path, lane: Lane) -> Option<String> {
    let (version, open) = lane_tasks(dir, lane)?;

    let mut s = format!(
        "## {} · {version} — {}\n",
        linked_name(name, &lane.dir(dir)),
        counts(&open, lane, name, dir)
    );
    if open.is_empty() {
        // On the HUMAN board an idle project is a fact worth rendering: omitting it would
        // read as "not set up" rather than "nothing queued". On the agent board it is noise -
        // every project is scaffolded with an empty agent sheet, so rendering the idle ones
        // buries the working ones under sixteen empty stanzas.
        if lane == Lane::Agent {
            return None;
        }
        s.push_str("_(nothing queued)_\n");
    }
    for l in listed(&open, lane) {
        s.push_str(&format!("- [ ] {}\n", render(l)));
    }
    if lane == Lane::Human {
        s.push_str(&playtest_line(dir).unwrap_or_default());
    }
    Some(s)
}

/// One project as a SINGLE line, for an org that is not the one you are working today.
///
/// The board has to hold every org or it is not a board, and it has to be readable or nobody
/// opens it. One client project contributing 47 multi-sentence rows made the two goals fight;
/// folding the orgs you are not in settles it without hiding anything, because the count is
/// still exact and the name is still a link to the full list. On the human board a project
/// with playtest checks waiting gets its playtest line indented under that one.
fn project_rollup_line(name: &str, dir: &std::path::Path, lane: Lane) -> Option<String> {
    let (version, open) = lane_tasks(dir, lane)?;
    if open.is_empty() && lane == Lane::Agent {
        return None; // same rule folded: an idle agent sheet is not worth a row
    }
    let mut s = format!(
        "- {} {version} - {}",
        linked_name(name, &lane.dir(dir)),
        counts(&open, lane, name, dir)
    );
    let next = listed(&open, lane).next().map(|l| render(l));
    if let Some(next) = next {
        s.push_str(&format!(" - next: {}", truncate_words(&next, 60)));
    }
    s.push('\n');
    if let Some(pl) = playtest_line(dir).filter(|_| lane == Lane::Human) {
        s.push_str(&format!("  {pl}"));
    }
    Some(s)
}

/// Truncate on a word boundary so a folded line stays one line. Never mid-word: a rollup is
/// a pointer, and a pointer that reads as garbled text is worse than a shorter one.
fn truncate_words(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out = String::new();
    for w in s.split_whitespace() {
        if out.chars().count() + w.chars().count() + 1 > max {
            break;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(w);
    }
    // A single word longer than `max` leaves `out` empty; hard-cut it rather than emit
    // nothing, so the row still says something.
    if out.is_empty() {
        out = s.chars().take(max).collect();
    }
    format!("{out}...")
}

/// A task line as the board shows it: checkbox stripped, HTML comments dropped. Keeps the
/// text the human typed, so a board row is greppable back to its sheet.
///
/// A stray `#ai` is deliberately NOT stripped. The tag routes nothing now, and a board that
/// silently swallowed it would render a tagged row identically to an untagged one - leaving
/// whoever typed it waiting on an agent that was never told. Let it show as the raw text it
/// is; `notes doctor` reports it.
fn render(line: &str) -> String {
    // `task_text`, not `task_key`: the latter lower-cases because it is a de-duplication
    // key, which turned every board row into `pr #423`.
    md::task_text(line)
}

/// Render + write the board across every configured profile. Returns its path.
///
/// A profile that fails to resolve is skipped rather than fatal: this runs from
/// `notes today`, and one broken profile must not stop the note being written — the same
/// rule `focus::list_all` follows.
pub fn write(log: &Logger) -> Result<Option<PathBuf>> {
    let active = config::resolve(None)?;
    // Before rendering: every project has an agent sheet, and its human sheet links there.
    // Here rather than in `write_one` because that runs once per LANE and this is per
    // project - and because a board that renders a link to a file nobody created is the
    // dangling-wikilink failure `link_for` exists to prevent.
    let _ = crate::agent_sheet::ensure_all(log);
    let human = board_path(&active);
    if let Some(p) = agent_board_path(&active) {
        write_one(log, &p, Lane::Agent)?;
        retire_ai_board(log, &p);
    }
    match human {
        Some(p) => write_one(log, &p, Lane::Human).map(Some),
        None => Ok(None),
    }
}

/// Delete the pre-rename `ai-board.md` once `agent-board.md` has been written in its place.
///
/// Without this the vault keeps a second board that nothing regenerates and nothing links: a
/// stale copy of the agent lane, frozen at whatever the last old binary wrote, indistinguishable
/// at a glance from the live one. That is the drift this whole layout exists to avoid.
///
/// Guarded on the `id: ai-board` line so it can only ever remove a file THIS code generated.
/// A best-effort cleanup, never fatal: a board that wrote fine must not fail the run (and
/// `notes today` calls this) because an old sibling could not be unlinked.
fn retire_ai_board(log: &Logger, agent_board: &std::path::Path) {
    let legacy = agent_board.with_file_name("ai-board.md");
    let Ok(content) = fs::read_to_string(&legacy) else {
        return;
    };
    if !content.lines().any(|l| l.trim() == "id: ai-board") {
        return;
    }
    match fs::remove_file(&legacy) {
        Ok(()) => log.info("board", &format!("retired {}", legacy.display())),
        Err(e) => log.info(
            "board",
            &format!("could not retire {}: {e}", legacy.display()),
        ),
    }
}

/// Render + write ONE board. Two lanes, one renderer, so `board.md` and `agent-board.md` cannot
/// disagree about what a project's list holds.
fn write_one(log: &Logger, path: &std::path::Path, lane: Lane) -> Result<PathBuf> {
    let today = Local::now().date_naive().format("%Y-%m-%d");
    let (id, title, blurb) = match lane {
        Lane::Human => (
            "board",
            "Board",
            "_Every project's `## Tasks` - the queue, every open item whoever does \
             it. What the agents are breaking down underneath it is on the \
             [[lab/projects/agent-board|agent board]]. Generated by `notes board` (and each \
             `notes today`) from the project sheets - edit a task on its project \
             sheet, never here._",
        ),
        Lane::Agent => (
            "agent-board",
            "Agent board",
            "_Each project's `agent/README.md` — the agents' working board: the subtasks and \
             state under a queue row, so interrupted work can be picked up. The queue \
             itself is on the [[lab/projects/board|board]]. Generated by `notes board`; edit \
             a task on its agent sheet, never here._",
        ),
    };
    let mut s = format!(
        "---\nid: {id}\ntags: [board, projects]\n---\n\n# {title} — {today}\n\n{blurb}\n\n"
    );

    // Order and fold are read from config, not decided here. A board whose lead org depends
    // on `names.sort()` puts the most important work first only by luck of the alphabet.
    let layout = config::board_layout().unwrap_or_default();

    let mut blocks = 0;
    for name in layout.sort(config::all_profile_names()?) {
        let Ok(p) = config::resolve(Some(&name)) else {
            continue;
        };
        let dirs = daily::discover_project_dirs(&p);
        if dirs.is_empty() {
            continue;
        }
        let full = layout.is_full(&name);
        let mut profile_blocks: Vec<String> = Vec::new();
        for (proj, summary) in &dirs {
            let Some(dir) = summary.parent() else {
                continue;
            };
            let rendered = if full {
                project_block(proj, dir, lane)
            } else {
                project_rollup_line(proj, dir, lane)
            };
            if let Some(b) = rendered {
                profile_blocks.push(b);
            }
        }
        if profile_blocks.is_empty() {
            continue;
        }
        // The profile is the grouping the human already thinks in (personal vs bnb vs a
        // job), and it is what `notes --profile X ptask` needs to act on a row.
        //
        // `_(folded)_` is load-bearing: without it a one-line-per-project org reads as a
        // project list that has lost its tasks, rather than a deliberate summary.
        if full {
            s.push_str(&format!("# {name}\n\n"));
        } else {
            s.push_str(&format!("# {name} _(folded)_\n\n"));
        }
        if lane == Lane::Agent {
            s.push_str(&format!("{}\n\n", agent_tiers(&p)));
        }
        for b in profile_blocks {
            blocks += 1;
            s.push_str(&b);
            // A full org's blocks are stanzas and each needs air; a folded org is ONE list
            // and a blank between its rows would break it into unrelated fragments.
            if full {
                s.push('\n');
            }
        }
        if !full {
            s.push('\n');
        }
    }

    if blocks == 0 {
        // Two different facts, and saying the wrong one sends you looking for a setup
        // problem that is not there. An idle agent board is the normal resting state.
        s.push_str(match lane {
            Lane::Human => "_(no project has a task sheet yet)_\n",
            Lane::Agent => "_(nothing in flight - no project has agent work open)_\n",
        });
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating board dir {}", parent.display()))?;
    }
    md::write_atomic(path, &s).with_context(|| format!("writing {}", path.display()))?;
    log.info(
        "board",
        &format!("wrote {blocks} project(s) to {}", path.display()),
    );
    Ok(path.to_path_buf())
}

/// `notes board --agent [--project N]...` — print the agent lane as `<project>\t<text>`.
///
/// The READ side of the board, for the session preflight: what an agent left unfinished on
/// this project, so a fresh session can pick the work up rather than restart it.
///
/// Three properties this must hold, all of them because a hook calls it at turn 1:
///
/// 1. NEVER writes. `run` regenerates board.md; this does not touch it. A preflight that
///    rewrites the human's board as a side effect of being asked a question is a
///    surprise, and it would fight `notes today` for the file.
/// 2. ALWAYS exits 0. No projects, no matches, no sheets, no `projects` dir configured --
///    all are ordinary answers meaning "nothing queued". Only a hard I/O error is an
///    error, and even then the caller guards with `|| true`.
/// 3. Reuses `lane_tasks` + `render`, so it cannot drift from what `agent-board.md` shows.
///    One resolver, not a second opinion about where a lane lives.
///
/// An empty `projects` filter means every project, so a caller that cannot resolve the
/// join still gets the whole lane rather than silence.
pub fn print_agent(projects: &[String]) -> Result<i32> {
    let wanted: Vec<String> = projects.iter().map(|p| p.to_lowercase()).collect();

    for name in config::all_profile_names()? {
        let Ok(p) = config::resolve(Some(&name)) else {
            continue;
        };
        for (proj, summary) in daily::discover_project_dirs(&p) {
            if !wanted.is_empty() && !wanted.contains(&proj.to_lowercase()) {
                continue;
            }
            let Some(dir) = summary.parent() else {
                continue;
            };
            for row in agent_rows_for_dir(&proj, dir) {
                println!("{row}");
            }
        }
    }
    Ok(0)
}

/// The per-project half of `print_agent`, split out so it is testable without a configured
/// profile tree. Returns `<project>\t<text>` rows from the agent sheet's open version.
///
/// WIRE FORMAT, not a display: `session-preflight.sh` splits these positionally on the tab.
/// Adding a column or a prefix breaks turn-1 injection in a hook that cannot report it.
fn agent_rows_for_dir(proj: &str, dir: &std::path::Path) -> Vec<String> {
    let Some((_version, open)) = lane_tasks(dir, Lane::Agent) else {
        return Vec::new();
    };
    open.iter()
        .map(|line| format!("{proj}\t{}", render(line)))
        .collect()
}

/// The rows of one sheet that belong to the release `want`, open and closed, when the sheet's
/// open version is `cur`. The same rule `notes projects --release` gates on and freezes by: a
/// row's release is its tag when that is ahead of `cur`, else `cur`, so an untagged row is in
/// the open version and a closed row aimed later waits for its own release.
fn release_rows(content: &str, cur: Option<V>, want: V) -> (Vec<String>, Vec<String>) {
    let ours = |l: &str| sheet::version_of(l, cur) == Some(want);
    let open = sheet::open_rows(content)
        .into_iter()
        .filter(|(_, l)| ours(l))
        .map(|(_, l)| l.trim_end().to_string())
        .collect();
    let lines: Vec<&str> = content.lines().collect();
    let span = md::section_span(&lines, sheet::TASKS).unwrap_or(0..0);
    let closed = project_tasks::done_rows(content)
        .into_iter()
        .filter(|r| span.contains(&r.start) && ours(lines[r.start]))
        .map(|r| lines[r.start].trim_end().to_string())
        .collect();
    (open, closed)
}

/// The top-level closed rows of a frozen note, or none when it does not exist.
fn frozen_rows(note: &std::path::Path) -> Vec<String> {
    note_rows(note, |_| true)
}

/// The closed rows of a version note whose place `keep` accepts: `true` for a row under the
/// human sheet's `## Sheet done rows`, `false` for any other.
fn note_rows(note: &std::path::Path, keep: impl Fn(bool) -> bool) -> Vec<String> {
    let Ok(content) = fs::read_to_string(note) else {
        return Vec::new();
    };
    let lines: Vec<&str> = content.lines().collect();
    let sheet_span = md::section_span(&lines, project_tasks::SHEET_DONE_ROWS);
    project_tasks::done_rows(&content)
        .into_iter()
        .filter(|r| keep(sheet_span.as_ref().is_some_and(|s| s.contains(&r.start))))
        .map(|r| lines[r.start].trim_end().to_string())
        .collect()
}

/// Rows with the lane each came from.
type LaneRows = Vec<(Lane, String)>;

/// One project's release `want` across both lanes: the live sheets' rows aimed at it, plus the
/// rows already frozen into `versions/<want>.md` (or the tag note it froze under, `frozen_note`)
/// or archived into `agent/versions/<want>.md`.
/// Each row carries its lane. Empty when nothing on this project is aimed at `want`.
fn release_view(dir: &std::path::Path, want: V) -> (LaneRows, LaneRows) {
    let ver = crate::projects::fmt_version(want);
    let (mut open, mut closed) = (Vec::new(), Vec::new());
    for lane in [Lane::Human, Lane::Agent] {
        let ldir = lane.dir(dir);
        if let Some(c) = project_tasks::task_sheet(&ldir).and_then(|s| fs::read_to_string(s).ok()) {
            let (o, d) = release_rows(&c, project_tasks::open_version_for(&ldir), want);
            open.extend(o.into_iter().map(|l| (lane, l)));
            closed.extend(d.into_iter().map(|l| (lane, l)));
        }
        // The agent note holds both lanes' rolled-off rows, each under its own section.
        let agent_note = crate::projects::agent_note_path(dir, &ver);
        let rows = match lane {
            Lane::Human => {
                let mut r = frozen_rows(&crate::projects::frozen_note(dir, &ver));
                r.extend(note_rows(&agent_note, |sheet| sheet));
                r
            }
            Lane::Agent => note_rows(&agent_note, |sheet| !sheet),
        };
        closed.extend(rows.into_iter().map(|l| (lane, l)));
    }
    (open, closed)
}

/// One release-view row: the board's text, then the lane when it is the agents', then the
/// PRs on a closed row or `dropped` for one closed undelivered.
fn release_line(lane: Lane, line: &str) -> String {
    let mark = if md::is_checked(line) { 'x' } else { ' ' };
    let mut s = format!("- [{mark}] {}", render(line));
    if lane == Lane::Agent {
        s.push_str(" (agent)");
    }
    if md::is_dropped(line) {
        s.push_str(" (dropped)");
    } else {
        let prs = md::pr_refs(line);
        if !prs.is_empty() {
            s.push_str(&format!(" (pr:{})", prs.join(" pr:")));
        }
    }
    s
}

/// `notes board --version vX.Y.Z [--project N]...` - print every row aimed at that release,
/// across every profile and both lanes: open rows first, then closed ones with their PRs.
///
/// READ-ONLY, like `--agent`: a release is a filter over the one list, so this is a view of the
/// sheets and the frozen notes, never a store. It shows what `notes projects --release` would
/// gate on (the open rows) and freeze (the closed ones). Exits 0 with no rows.
pub fn print_version(version: &str, projects: &[String]) -> Result<i32> {
    let want = crate::projects::parse_version(version.trim())
        .ok_or_else(|| anyhow::anyhow!("--version wants vX.Y.Z, got '{version}'"))?;
    let ver = crate::projects::fmt_version(want);
    let wanted: Vec<String> = projects.iter().map(|p| p.to_lowercase()).collect();
    let mut out = String::new();
    let (mut n_open, mut n_closed) = (0, 0);
    for name in config::all_profile_names()? {
        let Ok(p) = config::resolve(Some(&name)) else {
            continue;
        };
        for (proj, summary) in daily::discover_project_dirs(&p) {
            if !wanted.is_empty() && !wanted.contains(&proj.to_lowercase()) {
                continue;
            }
            let Some(dir) = summary.parent() else {
                continue;
            };
            let (open, closed) = release_view(dir, want);
            if open.is_empty() && closed.is_empty() {
                continue;
            }
            n_open += open.len();
            n_closed += closed.len();
            out.push_str(&format!(
                "\n## {name}/{proj} - {} open, {} closed\n",
                open.len(),
                closed.len()
            ));
            for (lane, l) in open.iter().chain(&closed) {
                out.push_str(&release_line(*lane, l));
                out.push('\n');
            }
        }
    }
    println!("# {ver} - {n_open} open, {n_closed} closed");
    if out.is_empty() {
        println!("\n_(no row is aimed at {ver})_");
    } else {
        print!("{out}");
    }
    Ok(0)
}

/// One row of the task feed: `notes board --json`, the one shape every board UI reads. Open
/// rows are the feed's `rows`, closed ones its `done`.
///
/// A VIEW over the sheets, never a store: each field is read off the line on each call, and
/// `raw` is the line itself, which a UI hands back to `notes ptask --exact` to act on it.
/// `version` is the sheet's version (`None` for a playtest check, which has none) and `game`
/// the playtest heading (`None` on a sheet row).
#[derive(Clone, Debug, serde::Serialize, PartialEq)]
struct FeedRow {
    profile: String,
    /// None for a Focus row: the daily cockpit belongs to the profile, not a project.
    project: Option<String>,
    lane: &'static str,
    version: Option<String>,
    game: Option<String>,
    state: &'static str,
    priority: &'static str,
    /// `#tier/N`: how hard the row is, which `fleet-dispatch` matches against a worker's max.
    tier: Option<u8>,
    /// `#worker/<name>`: the dispatch worker the row is assigned to.
    worker: Option<String>,
    /// `#requested`: the human asked for this row (their quote rides in it); never dispatched at night.
    requested: bool,
    /// The row's own `#vX.Y.Z` tag: the release it is aimed at.
    /// `<!-- id:<code>-<n> -->`: the row's stable id, which every `ptask` verb takes as a query.
    id: Option<String>,
    /// The `type(area):` prefix split out; `None` on a row without a well-formed one.
    r#type: Option<String>,
    area: Option<String>,
    /// `#size/s|m|l`: s a small single PR, m one PR, l needs a plan. The band of `points`
    /// when the row has them ([`crate::epics::POINTS`]), else its own `#size/` tag.
    size: Option<String>,
    /// `#pts/<n>`: the row's effort estimate on the points scale, `None` when unscored.
    points: Option<u32>,
    text: String,
    tags: Vec<String>,
    /// `tags` as written: `tags` is lower-cased for grouping, and a gate tag's value is data
    /// (`#ask/kxL6vp`), which agent-queue `gate` reads from here.
    tags_cased: Vec<String>,
    marker: Option<String>,
    since: Option<String>,
    /// `filed:YYYY-MM-DD` in the marker: the day the triager filed it from an inbox.
    filed: Option<String>,
    sheet: String,
    line: usize,
    raw: String,
    /// The lines indented under the row (`goal:`, `check:`, children), trimmed; empty for a
    /// Focus or playtest row.
    details: Vec<String>,
    /// False when the row's profile has `automation = false`: board automation (dispatch,
    /// triage) skips it, and the UIs still show it.
    automation: bool,
    /// The line carries no priority tag: `priority` is the rank's default, and
    /// `agentctl-inbox-triage --backlog --priority` gives it a real one.
    untriaged: bool,
    /// The sheet section the sweep lays the row out in: `epics`, `now`, `next`, `board` (an
    /// agent-board row inside the budget), `backlog`, or `done` for a closed row
    /// ([`project_sweep::section_of`]). `None` on a Focus or playtest row, which no sheet
    /// section holds.
    section: Option<&'static str>,
    /// An agent-board row past the board budget: its marker carries `tier:backlog`
    /// ([`project_sweep::BACKLOG`]), which dispatch does not pull from and Board does not count.
    backlog: bool,
    /// [`crate::rank`] as one number, smaller sooner: within a section, the sheet's order.
    /// Comparable across sheets, so a reader sorts by it instead of deriving its own order.
    rank: u64,
    /// `#dueMMDD` as `YYYY-MM-DD`.
    due: Option<String>,
    /// The project's target day (`Target:`, as `YYYY-MM-DD`) when the row is aimed at the targeted
    /// version ([`crate::rank::Aim`]): the due date `rank` reads beside `due`, never a pin.
    release_due: Option<String>,
    /// The id the row's `#of/<id>` names: its epic or story.
    parent: Option<String>,
    /// The `#size/` weight ([`crate::epics::WEIGHTS`], 1 unsized): what a forecast sums.
    weight: u32,
    /// `done:YYYY-MM-DD`: the day a closed row closed. `None` on an open row.
    closed: Option<String>,
    /// The PRs the marker names (`pr:<n>`).
    prs: Vec<String>,
}

/// One project in the feed, rows or not: a UI needs every project to offer `add` on it.
#[derive(Debug, serde::Serialize)]
struct FeedProject {
    profile: String,
    project: String,
    dir: String,
    version: Option<String>,
    open: usize,
    /// The agent rows on the board, not counting `agent_backlog`.
    agent_open: usize,
    /// The agent rows in the Backlog tier ([`FeedRow::backlog`]).
    agent_backlog: usize,
    /// Open feature epics on the human sheet aimed at a release (`#vX.Y.Z`), and the untagged
    /// ones not yet aimed at any ([`crate::epics::strip_counts`]).
    epic_open: usize,
    epic_backlog: usize,
    playtest_open: usize,
    /// Lines waiting in the sheet's `## Inbox` for the triager.
    inbox: usize,
    /// Closed rows past the Done window on both sheets, which the next sweep rolls off:
    /// `fleet-bench chain`'s `done_inline_old`.
    done_old: usize,
    /// The profile's `automation` key (see [`FeedRow::automation`]).
    automation: bool,
    /// The open version's release window counted ([`crate::window::Sprint::of`]), `None` when it has none:
    /// then its agent board is the rolling Today tier alone.
    sprint: Option<crate::window::Sprint>,
    /// The rows that window holds ([`crate::window::tasks`]), which `sprint` counts; carried on
    /// the project's [`FeedSprint`], not here.
    #[serde(skip)]
    tasks: Vec<crate::window::Task>,
}

impl FeedProject {
    /// Its window, agent board and feature epics in [`tiers`]'s words.
    fn tiers(&self) -> String {
        tiers(
            self.sprint.unwrap_or_default(),
            self.agent_open,
            self.agent_backlog,
            (self.epic_open, self.epic_backlog),
        )
    }
}

/// The board's one count: every open row (open or doing) on the human, agent and playtest
/// sheets of every profile, never a Focus or closed row. Home's Board card and the waybar
/// hover's `all lanes` line show `open`; the tiers line's Today, waybar's `T` and the hub and
/// agent-web Projects strip show `agent`, the agent board dispatch pulls from, so none counts
/// for itself. An agent row in the Backlog tier is not on the board: it is counted in `backlog`
/// alone. `sprint` is every project's release window summed (the tiers line's Sprint and
/// waybar's `S`), and `epic_open` and `epic_backlog` every project's feature epics
/// ([`tiers`]: `Sprint O/C | Today N | Backlog M | Epics E | Epic backlog B`).
#[derive(Debug, Default, serde::Serialize, PartialEq)]
struct Totals {
    open: usize,
    doing: usize,
    human: usize,
    agent: usize,
    playtest: usize,
    backlog: usize,
    epic_open: usize,
    epic_backlog: usize,
    sprint: crate::window::Sprint,
}

impl Totals {
    /// The totals in [`tiers`]'s words.
    fn tiers(&self) -> String {
        tiers(
            self.sprint,
            self.agent,
            self.backlog,
            (self.epic_open, self.epic_backlog),
        )
    }

    fn of(rows: &[FeedRow], projects: &[FeedProject]) -> Totals {
        let mut t = Totals {
            epic_open: projects.iter().map(|p| p.epic_open).sum(),
            epic_backlog: projects.iter().map(|p| p.epic_backlog).sum(),
            ..Totals::default()
        };
        for s in projects.iter().filter_map(|p| p.sprint) {
            t.sprint += s;
        }
        for r in rows.iter().filter(|r| r.state != "done") {
            if r.backlog {
                t.backlog += 1;
                continue;
            }
            match r.lane {
                "human" => t.human += 1,
                "agent" => t.agent += 1,
                "playtest" => t.playtest += 1,
                _ => continue,
            }
            t.open += 1;
            t.doing += usize::from(r.state == "doing");
        }
        t
    }
}

#[derive(serde::Serialize)]
struct Feed {
    today: String,
    totals: Totals,
    projects: Vec<FeedProject>,
    rows: Vec<FeedRow>,
    /// Closed rows, newest first: each sheet's `### Done`, and with `--done-days N` the rows
    /// rolled into `agent/versions/` too, closed in the last N days. Never dropped rows.
    done: Vec<FeedRow>,
    /// One line per open release window ([`sprint_lines`]), the words every surface shows beside
    /// `totals.sprint`, their sum.
    sprints: Vec<FeedSprint>,
}

/// One focus window as the feed carries it: its counts and cut for a reader that sorts or
/// colours, and `line`, the one formatter's words ([`crate::window::sprint_line`]) for every
/// reader that shows it.
#[derive(Debug, PartialEq, serde::Serialize)]
struct FeedSprint {
    profile: String,
    project: String,
    version: String,
    done: usize,
    committed: usize,
    /// The window's due day, `YYYY-MM-DD`.
    due: Option<String>,
    /// The cut row's moment, `YYYY-MM-DDTHH:MM`, when one names the project.
    cut: Option<String>,
    build: crate::window::Build,
    /// What the last cut carried into this window, `None` before any cut was scored.
    carried: Option<usize>,
    line: String,
    /// The day the window opened, `YYYY-MM-DD`.
    opened: String,
    /// When a sprint lock was taken, `YYYY-MM-DDTHH:MM`; `None` for a window recorded at a cut.
    locked: Option<String>,
    /// The next version's sprint, locked while the open one runs ([`crate::window::queue_sprint`]):
    /// it has not started.
    queued: bool,
    /// When a queued sprint starts, `YYYY-MM-DDTHH:MM`: the cut of the window before it.
    start: Option<String>,
    /// The rows the window holds, as they stand.
    tasks: Vec<crate::window::Task>,
    /// The weight of the tasks still open or in progress.
    remaining_weight: u32,
    /// The agent lane's shipped weight per hour over the budget window
    /// ([`crate::window::rate_per_hour`]); 0.0 with no shipping history.
    rate_per_hour: f64,
}

/// How many days past a window's due day its cut row may be gated and still be its cut: a late
/// cut is this window's, a release weeks on is not. Provisional (2026-11-19, a guess from one
/// window that cut a day late); revisit when a cut slips further.
const CUT_SLACK_DAYS: i64 = 3;

/// Whether `text` holds `name` as a whole word: no letter, digit or `-` either side, so a short name
/// does not match inside another word.
fn names_word(text: &str, name: &str) -> bool {
    let word = |c: char| c.is_alphanumeric() || c == '-';
    text.match_indices(name).any(|(i, m)| {
        !text[..i].chars().next_back().is_some_and(word)
            && !text[i + m.len()..].chars().next().is_some_and(word)
    })
}

/// The cut row of the window `frame` describes, among `rows` (open) and `done`: a `release(...)`
/// row of the project's profile that names the project (its own, or in its text, as the release
/// skill's title names every target) and carries a dated `#at/` gate after the day the window
/// opened to [`CUT_SLACK_DAYS`] past its due day (a later gate is another release, such as a
/// festival demo). The gate nearest the due day wins.
fn cut_of<'a>(
    fp: &FeedProject,
    frame: &crate::window::Frame,
    (rows, done): (&'a [FeedRow], &'a [FeedRow]),
    now: chrono::NaiveDateTime,
) -> Option<crate::window::Cut> {
    use crate::window::{Build, Cut};
    let name = fp.project.to_lowercase();
    let named = |r: &FeedRow| {
        r.project.as_deref() == Some(fp.project.as_str())
            || names_word(&r.text.to_lowercase(), &name)
    };
    let found = |r: &'a FeedRow| {
        let at = project_sweep::at_dated(&r.raw)?;
        (r.profile == fp.profile
            && r.r#type.as_deref() == Some("release")
            && named(r)
            && at.date() > frame.opened
            && frame
                .due
                .is_none_or(|d| (at.date() - d).num_days() <= CUT_SLACK_DAYS))
        .then_some((r, at))
    };
    rows.iter()
        .chain(done)
        .filter_map(found)
        .min_by_key(|(_, at)| {
            let off = frame.due.map_or(0, |d| (at.date() - d).num_days().abs());
            (off, *at)
        })
        .map(|(r, at)| Cut {
            at,
            build: match r.state {
                "done" => Build::Built,
                "doing" => Build::Building,
                _ if at > now => Build::Held,
                _ => Build::Queued,
            },
        })
}

/// A line for every project with a recorded release window, in feed order, each followed by
/// the next version's sprint when one is queued behind it ([`crate::window::queue_sprint`]).
fn sprint_lines(
    projects: &[FeedProject],
    rows: (&[FeedRow], &[FeedRow]),
    now: chrono::NaiveDateTime,
) -> Vec<FeedSprint> {
    projects
        .iter()
        .flat_map(|fp| {
            let dir = std::path::Path::new(&fp.dir);
            let Some(cur) = fp
                .version
                .as_deref()
                .and_then(crate::projects::parse_version)
            else {
                return Vec::new();
            };
            let open = fp
                .sprint
                .zip(crate::window::frame(dir, cur))
                .map(|(s, f)| feed_sprint(fp, (cur, s, &f, &fp.tasks), rows, now));
            let next = crate::projects::next_version(Some(cur), crate::projects::Bump::Patch);
            let queued = crate::window::frame(dir, next).and_then(|f| {
                let tasks = crate::window::tasks(dir, next)?;
                let s = crate::window::Sprint::of(&tasks);
                Some(feed_sprint(fp, (next, s, &f, &tasks), rows, now))
            });
            open.into_iter().chain(queued).collect()
        })
        .collect()
}

/// One window's [`FeedSprint`]: version `v` of project `fp`, its count, frame and tasks.
fn feed_sprint(
    fp: &FeedProject,
    (v, sprint, frame, tasks): (
        crate::sheet::V,
        crate::window::Sprint,
        &crate::window::Frame,
        &[crate::window::Task],
    ),
    rows: (&[FeedRow], &[FeedRow]),
    now: chrono::NaiveDateTime,
) -> FeedSprint {
    let version = crate::projects::fmt_version(v);
    let moment = |m: chrono::NaiveDateTime| m.format(crate::window::CUT_FORMAT).to_string();
    // A sprint lock's cut ends the sprint even when no cut row names the project yet.
    let cut = cut_of(fp, frame, rows, now).or(frame.cut.map(|at| crate::window::Cut {
        at,
        build: crate::window::Build::None,
    }));
    let line = crate::window::sprint_line(&fp.project, &version, sprint, (frame, cut), now.date());
    FeedSprint {
        profile: fp.profile.clone(),
        project: fp.project.clone(),
        version,
        done: sprint.committed.saturating_sub(sprint.open),
        committed: sprint.committed,
        due: frame.due.map(|d| d.to_string()),
        cut: cut.map(|c| moment(c.at)),
        build: cut.map_or(crate::window::Build::None, |c| c.build),
        carried: frame.carried,
        line,
        opened: frame.opened.to_string(),
        locked: frame.locked.map(moment),
        queued: frame.queued,
        start: frame.start.map(moment),
        remaining_weight: tasks.iter().filter(|t| t.is_open()).map(|t| t.weight).sum(),
        tasks: tasks.to_vec(),
        rate_per_hour: crate::window::rate_per_hour(std::path::Path::new(&fp.dir)),
    }
}

/// Where a feed row was read: everything about it that is not on the line.
struct Origin<'a> {
    profile: &'a str,
    project: Option<&'a str>,
    lane: &'static str,
    version: Option<&'a str>,
    game: Option<&'a str>,
    sheet: &'a std::path::Path,
    /// A project sheet's row, which the sweep lays out in a section; false for Focus and
    /// playtest rows.
    sheet_row: bool,
    /// The project's targeted version and the rows aimed at it, for the rank of an open row;
    /// `None` off a project sheet, or with no target.
    aim: Option<&'a crate::rank::Aim>,
}

/// The feed row for one open task `line`. Priority is the line's tag, else the rank's default
/// (`md::default_priority`) with `untriaged` set, so a reader orders it and triage still finds it. `tags` are the hashtags no other field already
/// carries: not the priority, tier, worker, requested, size, release tag or created tag
/// (`since`).
fn feed_row(
    o: &Origin,
    (line_no, line): (usize, &str),
    details: Vec<String>,
    today: chrono::NaiveDate,
) -> FeedRow {
    let tagged = md::task_priority(line);
    let prio = tagged.unwrap_or(md::default_priority());
    let priority = md::PRIORITIES
        .iter()
        .find(|(_, tag, _)| *tag == prio)
        .map_or("high", |(word, _, _)| word);
    let words: Vec<&str> = md::PRIORITIES.iter().map(|(w, _, _)| *w).collect();
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    let cased = md::find_hashtags_cased(head);
    let all: Vec<String> = cased.iter().map(|t| t.to_lowercase()).collect();
    let tier = all.iter().find_map(|t| md::tier_tag(t));
    let worker = all
        .iter()
        .find_map(|t| t.strip_prefix("worker/").map(str::to_string));
    let requested = all.iter().any(|t| t == "requested");
    let points = crate::projects::points_of(line);
    let size = crate::projects::size_name(line);
    let (ty, area) = crate::projects::row_type_area(line).unzip();
    let (tags, tags_cased): (Vec<String>, Vec<String>) = all
        .into_iter()
        .zip(cased)
        .filter(|(t, _)| {
            !words.contains(&t.as_str())
                && !md::is_version_tag(t)
                && !md::is_created_tag(t)
                && !md::is_done_tag(t)
                && !md::is_backlog_tag(t)
                && !md::looks_like_tier(t)
                && !t.starts_with("worker/")
                && !t.starts_with("size/")
                && !t.starts_with("pts/")
                && t != "requested"
        })
        .unzip();
    FeedRow {
        profile: o.profile.to_string(),
        project: o.project.map(str::to_string),
        lane: o.lane,
        version: o.version.map(str::to_string),
        game: o.game.map(str::to_string),
        state: if md::is_checked(line) {
            "done"
        } else if line.trim_start().starts_with("- [/]") {
            "doing"
        } else {
            "open"
        },
        priority,
        tier,
        worker,
        requested,
        id: md::row_id(line),
        r#type: ty,
        area,
        size,
        points,
        text: md::task_text(line),
        tags,
        tags_cased,
        marker: md::marker_of(line),
        since: md::find_since(line, today).map(|d| d.format("%Y-%m-%d").to_string()),
        filed: project_tasks::filed_on(line),
        sheet: o.sheet.display().to_string(),
        line: line_no,
        raw: line.trim_end().to_string(),
        details,
        automation: true,
        untriaged: tagged.is_none(),
        section: o.sheet_row.then(|| {
            if md::is_checked(line) {
                "done"
            } else {
                project_sweep::section_of(line, o.lane == "agent").name()
            }
        }),
        backlog: o.lane == "agent" && project_sweep::in_backlog(line),
        rank: crate::rank::aimed(line, today, o.aim).key(),
        due: md::find_due(line, today).map(|d| d.format("%Y-%m-%d").to_string()),
        release_due: o
            .aim
            .and_then(|a| a.due_of(line))
            .map(|d| d.format("%Y-%m-%d").to_string()),
        parent: crate::epics::parent_of(line),
        weight: crate::projects::size_weight(line),
        closed: project_tasks::done_on(line).map(|d| d.format("%Y-%m-%d").to_string()),
        prs: md::pr_refs(line),
    }
}

/// Every open row of one project dir: its sheet's open version, its agent sheet's, and its
/// playtest checks, in that order. Split from [`print_json`] to test without a vault.
fn feed_for_dir(
    profile: &str,
    project: &str,
    dir: &std::path::Path,
    today: chrono::NaiveDate,
) -> (FeedProject, Vec<FeedRow>) {
    let mut rows = Vec::new();
    let mut version = None;
    let mut counts = [0usize; 3];
    let mut inbox = 0;
    let mut agent_backlog = 0;
    let mut done_old = 0;
    let aim = crate::rank::Aim::of(dir);
    for (i, (lane, name)) in [(Lane::Human, "human"), (Lane::Agent, "agent")]
        .into_iter()
        .enumerate()
    {
        let Some(w) = project_tasks::current_rows_for_dir(&lane.dir(dir)) else {
            continue;
        };
        if lane == Lane::Human {
            version = Some(w.version.clone());
            inbox = w.inbox;
        }
        let backlog = w
            .rows
            .iter()
            .filter(|r| lane == Lane::Agent && project_sweep::in_backlog(&r.text))
            .count();
        counts[i] = w.rows.len() - backlog;
        agent_backlog += backlog;
        done_old += w.done_old;
        let o = Origin {
            profile,
            project: Some(project),
            lane: name,
            version: Some(&w.version),
            game: None,
            sheet: &w.sheet,
            sheet_row: true,
            aim: aim.as_ref(),
        };
        for r in w.rows {
            rows.push(feed_row(&o, (r.line, &r.text), r.details, today));
        }
    }
    let file = crate::playtest::path(dir);
    if let Ok(content) = fs::read_to_string(&file) {
        for (n, game, l) in crate::playtest::open_rows(&content) {
            counts[2] += 1;
            let o = Origin {
                profile,
                project: Some(project),
                lane: "playtest",
                version: None,
                game: Some(&game),
                sheet: &file,
                sheet_row: false,
                aim: None,
            };
            rows.push(feed_row(&o, (n, l), Vec::new(), today));
        }
    }
    let (epic_open, epic_backlog) = crate::epics::strip_counts(dir);
    let tasks = version
        .as_deref()
        .and_then(crate::projects::parse_version)
        .and_then(|v| crate::window::tasks(dir, v));
    let proj = FeedProject {
        sprint: tasks.as_deref().map(crate::window::Sprint::of),
        tasks: tasks.unwrap_or_default(),
        profile: profile.to_string(),
        project: project.to_string(),
        dir: dir.display().to_string(),
        version,
        open: counts[0],
        agent_open: counts[1],
        agent_backlog,
        epic_open,
        epic_backlog,
        playtest_open: counts[2],
        inbox,
        done_old,
        automation: true,
    };
    (proj, rows)
}

/// The weight the agent rows of project `dir` closed with a PR in the last `days` days: its
/// shipped throughput, which sizes the agent board's budget. A close with no PR (a stage-check
/// auto-close) is not counted.
pub(crate) fn shipped_weight(
    project: &str,
    dir: &std::path::Path,
    today: chrono::NaiveDate,
    days: i64,
) -> u32 {
    done_for_dir("", project, dir, today, Some(days))
        .iter()
        .filter(|r| r.lane == "agent" && !r.prs.is_empty())
        .map(|r| r.weight)
        .sum()
}

/// The closed rows of one project dir, both lanes, newest first: each sheet's `### Done` rows
/// of the open version, and with `days`, also the rows rolled into `agent/versions/*.md`, all
/// closed in the last `days` days. Dropped rows never: Done is finished work.
fn done_for_dir(
    profile: &str,
    project: &str,
    dir: &std::path::Path,
    today: chrono::NaiveDate,
    days: Option<i64>,
) -> Vec<FeedRow> {
    let recent = |line: &str| {
        days.is_none_or(|n| {
            project_tasks::done_on(line).is_some_and(|d| (0..n).contains(&(today - d).num_days()))
        })
    };
    let mut out = Vec::new();
    let mut take = |o: &Origin, content: &str, ranges: Vec<std::ops::Range<usize>>| {
        let lines: Vec<&str> = content.lines().collect();
        for r in ranges {
            let line = lines[r.start];
            if md::is_dropped(line) || !recent(line) {
                continue;
            }
            let details = lines[r.start + 1..r.end]
                .iter()
                .map(|l| l.trim().to_string())
                .collect();
            out.push(feed_row(o, (r.start + 1, line), details, today));
        }
    };
    for (lane, name) in [(Lane::Human, "human"), (Lane::Agent, "agent")] {
        let ldir = lane.dir(dir);
        let Some(path) = project_tasks::task_sheet(&ldir) else {
            continue;
        };
        let Ok(content) = fs::read_to_string(&path) else {
            continue;
        };
        let cur = project_tasks::open_version_for(&ldir);
        let version = crate::projects::version_or_default(cur);
        let o = Origin {
            profile,
            project: Some(project),
            lane: name,
            version: Some(&version),
            game: None,
            sheet: &path,
            sheet_row: true,
            aim: None,
        };
        take(&o, &content, project_tasks::done_rows_of(&content, cur));
    }
    let notes = days
        .map(|_| crate::projects::version_notes(&crate::projects::agent_dir(dir).join("versions")))
        .unwrap_or_default();
    for (v, note) in notes {
        let Ok(content) = fs::read_to_string(&note) else {
            continue;
        };
        let version = Some(crate::projects::fmt_version(v));
        let lines: Vec<&str> = content.lines().collect();
        for lane in [Lane::Human, Lane::Agent] {
            let Some(span) = md::section_span(&lines, project_tasks::archive_section(lane)) else {
                continue;
            };
            let o = Origin {
                profile,
                project: Some(project),
                lane: if lane == Lane::Human {
                    "human"
                } else {
                    "agent"
                },
                version: version.as_deref(),
                game: None,
                sheet: &note,
                sheet_row: true,
                aim: None,
            };
            let ranges = project_tasks::done_rows(&content)
                .into_iter()
                .filter(|r| span.contains(&r.start))
                .collect();
            take(&o, &content, ranges);
        }
    }
    out.sort_by_key(|r| std::cmp::Reverse(r.closed.clone()));
    out
}

/// A profile's open Focus rows from today's daily note, lane `focus`, no project. Read-only
/// here: `notes focus` stays their one writer.
fn focus_rows(profile: &str, note: &std::path::Path, today: chrono::NaiveDate) -> Vec<FeedRow> {
    let Ok(content) = fs::read_to_string(note) else {
        return Vec::new();
    };
    let o = Origin {
        profile,
        project: None,
        lane: "focus",
        version: None,
        game: None,
        sheet: note,
        sheet_row: false,
        aim: None,
    };
    crate::focus::open_focus_positions(&content)
        .into_iter()
        .map(|(n, _, l)| feed_row(&o, (n, &l), Vec::new(), today))
        .collect()
}

/// `notes board --json` - every project of every profile and every open row, as one JSON
/// object `{today, projects: [...], rows: [...]}`.
///
/// READ-ONLY and exit 0 like `--agent`: the web and hub boards poll it. Every profile is
/// listed in full whatever the board layout folds, because a UI filters for itself.
pub fn print_json(done_days: Option<i64>) -> Result<i32> {
    let today = Local::now().date_naive();
    let mut feed = Feed {
        today: today.format("%Y-%m-%d").to_string(),
        totals: Totals::default(),
        projects: Vec::new(),
        rows: Vec::new(),
        done: Vec::new(),
        sprints: Vec::new(),
    };
    let layout = config::board_layout().unwrap_or_default();
    for name in layout.sort(config::all_profile_names()?) {
        let Ok(p) = config::resolve(Some(&name)) else {
            continue;
        };
        feed.rows
            .extend(focus_rows(&name, &daily::today_path(&p), today));
        let automation = config::automation(&name);
        for (proj, summary) in daily::discover_project_dirs(&p) {
            let Some(dir) = summary.parent() else {
                continue;
            };
            let (mut fp, mut rows) = feed_for_dir(&name, &proj, dir, today);
            let mut done = done_for_dir(&name, &proj, dir, today, done_days);
            fp.automation = automation;
            for r in rows.iter_mut().chain(done.iter_mut()) {
                r.automation = automation;
            }
            feed.projects.push(fp);
            feed.rows.extend(rows);
            feed.done.extend(done);
        }
    }
    // Newest close first across every project; equal days keep feed order.
    feed.done
        .sort_by_key(|r| std::cmp::Reverse(r.closed.clone()));
    feed.totals = Totals::of(&feed.rows, &feed.projects);
    feed.sprints = sprint_lines(
        &feed.projects,
        (&feed.rows, &feed.done),
        Local::now().naive_local(),
    );
    println!("{}", serde_json::to_string(&feed)?);
    Ok(0)
}

/// `notes board` — regenerate, then print the path so the caller can open it.
pub fn run(log: &Logger) -> Result<i32> {
    match write(log)? {
        Some(p) => {
            println!("{}", p.display());
            Ok(0)
        }
        None => {
            eprintln!("no `projects` dir configured for this profile — nothing to board");
            Ok(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_strips_the_checkbox_but_keeps_every_word() {
        assert_eq!(
            render("- [ ] agentctl roles (0d) <!-- since:2026-08-05 -->"),
            "agentctl roles"
        );
        assert_eq!(render("- [ ] plain one"), "plain one");
    }

    // A tag that routes nothing must not be rendered as though it did. Swallowing it would
    // make a tagged row indistinguishable from an untagged one, which is how someone ends up
    // waiting on an agent nothing ever told.
    #[test]
    fn a_stray_ai_tag_shows_as_the_raw_text_it_is() {
        assert_eq!(render("- [ ] agentctl roles #ai"), "agentctl roles #ai");
    }

    #[test]
    fn each_board_reads_its_own_sheet() {
        let dir = sheet(
            "demo",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] human task\n- [ ] tagged but still mine #ai\n- [x] done one\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] agent subtask\n- [ ] someday maybe <!-- tier:backlog -->\n",
        );

        // The queue holds every open row on the human's sheet, tag or no tag. The lane no
        // longer filters, so the human board can no longer hide a row from its own list.
        let human = project_block("demo", &dir, Lane::Human).unwrap();
        assert!(human.contains("## demo · v0.3.0 — 2 open"), "{human}");
        assert!(human.contains("human task"), "{human}");
        assert!(human.contains("tagged but still mine"), "{human}");
        assert!(
            !human.contains("agent subtask"),
            "the agent sheet is a different file:\n{human}"
        );

        let agent = project_block("demo", &dir, Lane::Agent).unwrap();
        // The agent board lists its board rows and counts its Backlog tier beside them.
        assert!(
            agent.contains("## demo · v0.3.0 — Today 1 | Backlog 1 | Epics 0 | Epic backlog 0\n"),
            "{agent}"
        );
        assert!(agent.contains("- [ ] agent subtask"), "{agent}");
        assert!(!agent.contains("someday maybe"), "{agent}");
        assert!(!agent.contains("human task"), "{agent}");

        // the checked item counts for neither
        assert!(!human.contains("done one") && !agent.contains("done one"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    // Every project is scaffolded with an agent sheet whose only row is the empty `- [ ] `
    // placeholder. Rendering those would bury the working boards under sixteen empty stanzas.
    #[test]
    fn an_agent_sheet_holding_only_the_scaffold_placeholder_renders_nothing() {
        let dir = sheet(
            "idlebot",
            "# idlebot\nVersion: v0.1.0\n\n## Tasks\n- [ ] mine only\n",
        );
        write_agent_sheet(
            &dir,
            "# idlebot - agent board\nVersion: v0.1.0\n\n## Tasks\n- [ ] \n",
        );
        assert!(project_block("idlebot", &dir, Lane::Agent).is_none());
        assert!(project_rollup_line("idlebot", &dir, Lane::Agent).is_none());
        let h = project_block("idlebot", &dir, Lane::Human).unwrap();
        assert!(h.contains("mine only"), "{h}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_with_no_agent_dir_at_all_is_absent_not_an_error() {
        let dir = sheet(
            "bare",
            "# bare\nVersion: v0.1.0\n\n## Tasks\n- [ ] mine only\n",
        );
        assert!(project_block("bare", &dir, Lane::Agent).is_none());
        assert!(project_rollup_line("bare", &dir, Lane::Agent).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Location is the lane now, so the `#aid` substring trap cannot exist on this path: a
    // row on the agent sheet is an agent row whatever words it contains.
    #[test]
    fn a_row_is_classified_by_its_file_not_by_any_token_in_it() {
        let dir = sheet(
            "aidkit",
            "# aidkit\nVersion: v0.1.0\n\n## Tasks\n- [ ] restock #aid kit\n",
        );
        write_agent_sheet(
            &dir,
            "# aidkit - agent board\nVersion: v0.1.0\n\n## Tasks\n\
             - [ ] audit the #aid inventory\n",
        );
        let h = project_block("aidkit", &dir, Lane::Human).unwrap();
        assert!(h.contains("restock #aid kit"), "{h}");
        let a = project_block("aidkit", &dir, Lane::Agent).unwrap();
        assert!(a.contains("audit the #aid inventory"), "{a}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_list_still_renders_the_project() {
        let dir = std::env::temp_dir().join(format!("notes-board-e-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A sheet whose only row is the scaffold placeholder is EMPTY, not one item.
        std::fs::write(
            dir.join("README.md"),
            "# quiet\nVersion: v0.1.0\n\n## Tasks\n- [ ] \n",
        )
        .unwrap();

        let b = project_block("quiet", &dir, Lane::Human).unwrap();
        // Dropping the project entirely would read as "not set up" rather than "idle".
        assert!(b.contains("## quiet · v0.1.0 — 0 open"), "{b}");
        assert!(b.contains("nothing queued"), "{b}");
        assert!(
            !b.contains("(0 @ai)"),
            "no lane count when there is none:\n{b}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `sheet <name>` -> a temp project dir holding that README body.
    fn sheet(name: &str, body: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "notes-board-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("README.md"), body).unwrap();
        dir
    }

    const RELEASE_SHEET: &str =
        "# demo\nVersion: v1.13.0\n\n## Inbox\n- [ ] raw words\n\n## Tasks\n\
        - [ ] open now\n- [ ] open later #v1.14.0\n- [x] shipped now <!-- pr:7 -->\n  was: words\n\
        - [x] shipped early #v1.14.0 <!-- pr:8 -->\n- [x] old tag counts as now #v1.12.0\n";

    #[test]
    fn a_release_view_is_the_rows_the_release_would_gate_on_and_freeze() {
        let cur = Some((1, 13, 0));
        let (open, closed) = release_rows(RELEASE_SHEET, cur, (1, 13, 0));
        assert_eq!(open, vec!["- [ ] open now"]);
        assert_eq!(
            closed,
            vec![
                "- [x] shipped now <!-- pr:7 -->",
                "- [x] old tag counts as now #v1.12.0"
            ]
        );
        // A row aimed later is in ITS release, open or closed, and never in the open one.
        let (open, closed) = release_rows(RELEASE_SHEET, cur, (1, 14, 0));
        assert_eq!(open, vec!["- [ ] open later #v1.14.0"]);
        assert_eq!(closed, vec!["- [x] shipped early #v1.14.0 <!-- pr:8 -->"]);
        // NEGATIVE CONTROL: an inbox line is not on the board, and a release nothing is aimed
        // at is empty.
        let (open, closed) = release_rows(RELEASE_SHEET, cur, (2, 0, 0));
        assert!(open.is_empty() && closed.is_empty());
    }

    #[test]
    fn a_release_view_reads_both_lanes_and_the_frozen_notes() {
        let dir = sheet("relview", RELEASE_SHEET);
        write_agent_sheet(
            &dir,
            "# demo - agent board\n\n## Tasks\n- [ ] agent open\n- [x] agent stale <!-- dropped: superseded -->\n",
        );
        std::fs::create_dir_all(dir.join("versions")).unwrap();
        std::fs::write(
            dir.join("versions/v1.12.0.md"),
            "# demo\nVersion: v1.12.0\n\n## Tasks\n- [x] frozen row <!-- pr:3 -->\n",
        )
        .unwrap();

        let (open, closed) = release_view(&dir, (1, 13, 0));
        let open: Vec<String> = open.iter().map(|(l, r)| release_line(*l, r)).collect();
        let closed: Vec<String> = closed.iter().map(|(l, r)| release_line(*l, r)).collect();
        assert_eq!(open, vec!["- [ ] open now", "- [ ] agent open (agent)"]);
        assert_eq!(
            closed,
            vec![
                "- [x] shipped now (pr:7)",
                "- [x] old tag counts as now",
                "- [x] agent stale (agent) (dropped)"
            ]
        );
        // The agent note holds both lanes' rolled-off rows: each counts in its own lane.
        std::fs::create_dir_all(dir.join("agent/versions")).unwrap();
        std::fs::write(
            dir.join("agent/versions/v1.13.0.md"),
            "# n\n\n## Done rows\n- [x] agent rolled <!-- pr:5 -->\n\n\
             ## Sheet done rows\n- [x] human rolled <!-- pr:6 -->\n",
        )
        .unwrap();
        let (_, closed) = release_view(&dir, (1, 13, 0));
        let closed: Vec<String> = closed.iter().map(|(l, r)| release_line(*l, r)).collect();
        assert!(
            closed.contains(&"- [x] human rolled (pr:6)".to_string()),
            "{closed:?}"
        );
        assert!(
            closed.contains(&"- [x] agent rolled (agent) (pr:5)".to_string()),
            "{closed:?}"
        );
        assert!(
            !closed.iter().any(|l| l.contains("human rolled (agent)")),
            "{closed:?}"
        );
        // A frozen release is read from its note: the live sheet holds none of it.
        let (open, closed) = release_view(&dir, (1, 12, 0));
        assert!(open.is_empty());
        let closed: Vec<String> = closed.iter().map(|(l, r)| release_line(*l, r)).collect();
        assert_eq!(closed, vec!["- [x] frozen row (pr:3)"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Give a fixture project the agents' half, at the one path `Lane::Agent` resolves.
    fn write_agent_sheet(dir: &std::path::Path, body: &str) {
        let agent = dir.join("agent");
        std::fs::create_dir_all(&agent).unwrap();
        std::fs::write(agent.join("README.md"), body).unwrap();
    }

    #[test]
    fn agent_rows_emit_project_tab_text_from_the_agent_sheet_only() {
        let dir = sheet(
            "airows",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n- [ ] human task\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] agent task\n- [x] done one\n",
        );
        let rows = agent_rows_for_dir("demo", &dir);
        // Exactly the agent sheet's open rows: not the human's, not the checked one.
        assert_eq!(rows, vec!["demo\tagent task".to_string()], "{rows:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // `session-preflight.sh` splits this positionally on the tab. Two fields, no prefix: a
    // third column or a marker breaks turn-1 injection inside a hook that cannot report it.
    #[test]
    fn the_preflight_wire_format_is_two_tab_separated_fields() {
        let dir = sheet("wire", "# d\nVersion: v1\n\n## Tasks\n- [ ] only mine\n");
        write_agent_sheet(
            &dir,
            "# d - agent board\nVersion: v1\n\n## Tasks\n\
             - [ ] a thing #high <!-- pr:1218 -->\n",
        );
        let rows = agent_rows_for_dir("d", &dir);
        assert_eq!(rows, vec!["d\ta thing".to_string()]);
        assert_eq!(rows[0].split('\t').count(), 2, "{rows:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // done_old is the sweep's own roll-off rule read without a write: a row closed inside the
    // window stays, one closed past it, or with no `done:` date, counts on either sheet.
    #[test]
    fn the_feed_counts_the_done_rows_the_next_sweep_rolls_off() {
        let now = chrono::Local::now().date_naive().format("%Y-%m-%d");
        let dir = sheet(
            "feed-done-old",
            &format!(
                "# demo\nVersion: v0.3.0\n\n## Tasks\n- [ ] open one\n\n### Done\n\
                 - [x] closed today <!-- done:{now} -->\n- [x] closed long ago <!-- done:2020-01-01 -->\n"
            ),
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n- [x] undated close\n",
        );
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let (proj, _) = feed_for_dir("bnb", "demo", &dir, today);
        assert_eq!(
            proj.done_old, 2,
            "the 2020 row and the undated one, not today's"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The strip's epic pair: open feature epics on the human sheet, aimed at a release (any
    // `#v`, the open one or a later one) or not. A standing epic, a closed one, a leaf and an
    // epic on the agent sheet are not counted.
    #[test]
    fn the_feed_counts_feature_epics_aimed_and_untagged() {
        let dir = sheet(
            "feed-epics",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n\n### Epics\n\
             - [ ] epic(saves): cloud saves #v0.3.0 <!-- id:dm-1 -->\n\
             - [/] epic(menus): new menus #v0.4.0 <!-- id:dm-2 -->\n\
             - [ ] epic(audio): spatial audio <!-- id:dm-3 -->\n\
             - [ ] epic(ui): ui to standard <!-- id:dm-4 -->\n\
             - [x] epic(net): netcode #v0.3.0 <!-- id:dm-5 -->\n\n\
             ### Next up\n- [ ] feat(saves): sync #of/dm-1 <!-- id:dm-6 -->\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] epic(fleet): agent epic <!-- id:dm-7 -->\n- [ ] fix(fleet): a row <!-- id:dm-8 -->\n",
        );
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let (proj, rows) = feed_for_dir("bnb", "demo", &dir, today);
        assert_eq!((proj.epic_open, proj.epic_backlog), (2, 1));
        let two = [proj, feed_for_dir("bnb", "demo", &dir, today).0];
        let t = Totals::of(&rows, &two);
        assert_eq!(
            (t.epic_open, t.epic_backlog),
            (4, 2),
            "every project's, summed"
        );
        assert_eq!(
            counts(&[], Lane::Agent, "demo", &dir),
            "Today 2 | Backlog 0 | Epics 2 | Epic backlog 1",
            "the agent lane reads its feed entry, not the rows passed in"
        );
        // Negative control: no human sheet, no epics.
        let bare = sheet("feed-epics-bare", "");
        std::fs::remove_file(bare.join("README.md")).unwrap();
        assert_eq!(crate::epics::strip_counts(&bare), (0, 0));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&bare);
    }

    // The feed is what both board UIs read: every lane, each row parsed into the shared fields,
    // and `raw` exactly the line so `ptask --exact` can find it again.
    #[test]
    fn the_feed_reads_all_three_lanes_into_one_row_shape() {
        let dir = sheet(
            "feed",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] ship it #urgent #c1102 #v0.3.0 #due1110\n- [/] in flight\n- [x] closed\n\n\
             - [ ] later one #v0.4.0\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] fix(fleet): break it down #low #tier/2 #requested #worker/requested #keep #size/m \
             <!-- id:dm-7 ask:Ab12 -->\n\
             - [ ] chore(fleet): someday #low <!-- id:dm-8 tier:backlog -->\n",
        );
        std::fs::write(
            crate::playtest::path(&dir),
            "# Playtest\n\n## Arena\n- [ ] spawn 4 bots <!-- pr:812 -->\n",
        )
        .unwrap();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let (proj, rows) = feed_for_dir("bnb", "demo", &dir, today);

        assert_eq!(
            (
                proj.open,
                proj.agent_open,
                proj.agent_backlog,
                proj.playtest_open
            ),
            (2, 1, 1, 1),
            "the later row and the closed row are not on the board"
        );
        assert_eq!(proj.version.as_deref(), Some("v0.3.0"));
        let mut with_focus = rows.clone();
        with_focus.push(FeedRow {
            lane: "focus",
            ..rows[0].clone()
        });
        assert_eq!(
            Totals::of(&with_focus, std::slice::from_ref(&proj)),
            Totals {
                open: 4,
                doing: 1,
                human: 2,
                agent: 1,
                playtest: 1,
                backlog: 1,
                ..Default::default()
            },
            "the board's count: every open row of the three sheets, never a Focus, closed or \
             Backlog-tier row"
        );
        let lanes: Vec<&str> = rows.iter().map(|r| r.lane).collect();
        assert_eq!(lanes, ["human", "human", "agent", "agent", "playtest"]);
        let backlog: Vec<bool> = rows.iter().map(|r| r.backlog).collect();
        assert_eq!(backlog, [false, false, false, true, false]);
        let open_agent: Vec<Option<&str>> = rows
            .iter()
            .filter(|r| r.lane == "agent" && r.state == "open")
            .map(|r| r.section)
            .collect();
        assert_eq!(
            open_agent,
            [Some("board"), Some("backlog")],
            "an agent row is under the heading its tier names, as on the sheet"
        );

        let r = &rows[0];
        assert_eq!(r.text, "ship it");
        assert_eq!((r.state, r.priority), ("open", "urgent"));
        assert_eq!(
            r.tags,
            ["due1110"],
            "priority, version and created have their own fields"
        );
        assert_eq!(r.since.as_deref(), Some("2026-11-02"));
        assert_eq!(r.version.as_deref(), Some("v0.3.0"));
        assert_eq!((r.tier, r.requested), (None, false));
        assert_eq!(r.raw, "- [ ] ship it #urgent #c1102 #v0.3.0 #due1110");
        assert_eq!(r.line, 5);

        let r = &rows[1];
        assert_eq!(
            (r.state, r.priority),
            ("doing", "high"),
            "untagged means high"
        );

        let r = &rows[2];
        assert_eq!(
            (r.priority, r.tags.clone()),
            ("low", vec!["keep".to_string()]),
            "tier, requested, worker and size have their own fields"
        );
        assert_eq!(
            (r.id.as_deref(), r.r#type.as_deref(), r.area.as_deref()),
            (Some("dm-7"), Some("fix"), Some("fleet"))
        );
        assert_eq!(r.size.as_deref(), Some("m"));
        assert_eq!((r.tier, r.requested), (Some(2), true));
        assert_eq!(r.worker.as_deref(), Some("requested"));
        assert_eq!(r.project.as_deref(), Some("demo"));
        assert_eq!(r.marker.as_deref(), Some("id:dm-7 ask:Ab12"));
        assert!(r.sheet.ends_with("agent/README.md"), "{}", r.sheet);

        let r = &rows[4];
        assert_eq!(
            (r.version.clone(), r.game.as_deref()),
            (None, Some("Arena"))
        );
        assert_eq!(r.marker.as_deref(), Some("pr:812"));
        assert_eq!(r.text, "spawn 4 bots");

        // The serialized names are the contract the UIs read.
        let v = serde_json::to_value(&rows[0]).unwrap();
        for k in [
            "profile",
            "project",
            "lane",
            "version",
            "game",
            "state",
            "priority",
            "tier",
            "worker",
            "requested",
            "id",
            "type",
            "area",
            "size",
            "points",
            "text",
            "tags",
            "tags_cased",
            "marker",
            "since",
            "filed",
            "sheet",
            "line",
            "raw",
            "automation",
            "untriaged",
            "section",
            "backlog",
            "rank",
            "due",
            "parent",
            "weight",
            "closed",
            "prs",
        ] {
            assert!(v.get(k).is_some(), "missing {k}: {v}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The feed says where the sweep lays each row out and in what order, so a view groups and
    // sorts by `section` and `rank` instead of deriving its own (plan phase 2).
    #[test]
    fn each_row_carries_its_sheet_section_rank_due_and_parent() {
        let dir = sheet(
            "feedsections",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] epic(look): the look #high <!-- id:dm-1 -->\n\
             - [/] running #high <!-- id:dm-2 run:1109 -->\n\
             - [/] queued #low <!-- id:dm-3 -->\n\
             - [ ] child #urgent #of/dm-1 #due1110 #size/m <!-- id:dm-4 -->\n\
             - [ ] plain #low <!-- id:dm-5 -->\n",
        );
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 9).unwrap();
        let (_, rows) = feed_for_dir("bnb", "demo", &dir, today);
        let got: Vec<(Option<&str>, Option<&str>)> =
            rows.iter().map(|r| (r.id.as_deref(), r.section)).collect();
        assert_eq!(
            got,
            [
                (Some("dm-1"), Some("epics")),
                (Some("dm-2"), Some("now")),
                (Some("dm-3"), Some("next")),
                (Some("dm-4"), Some("backlog")),
                (Some("dm-5"), Some("backlog")),
            ]
        );
        let child = &rows[3];
        assert_eq!(child.due.as_deref(), Some("2026-11-10"));
        assert_eq!(child.parent.as_deref(), Some("dm-1"));
        assert_eq!(child.weight, 3);
        assert!(
            child.rank < rows[4].rank,
            "due tomorrow and #urgent rank ahead of a plain #low"
        );
        assert_eq!(child.rank, crate::rank::of(&child.raw, today).key());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A row aimed at the head's `Target:` version, here on the agent board under a human-sheet
    // epic, carries the target day in `release_due` and ranks as due on it; `due` stays its own.
    #[test]
    fn a_row_aimed_at_the_target_ranks_by_the_target_day() {
        let dir = sheet(
            "feedaim",
            "# demo\nVersion: v0.3.0\nTarget: v0.3.0 2026-11-10\n\n## Tasks\n\
             - [ ] epic(app): ship #v0.3.0 <!-- id:dm-1 -->\n",
        );
        let agent = crate::projects::agent_dir(&dir);
        std::fs::create_dir_all(&agent).unwrap();
        std::fs::write(
            agent.join("README.md"),
            "# demo agent\n\n## Tasks\n- [ ] plain #low #c1001 <!-- id:dm-2 -->\n\
             - [ ] aimed #low #c1002 #of/dm-1 <!-- id:dm-3 -->\n",
        )
        .unwrap();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 9).unwrap();
        let (_, rows) = feed_for_dir("bnb", "demo", &dir, today);
        let row = |id: &str| rows.iter().find(|r| r.id.as_deref() == Some(id)).unwrap();
        let (plain, aimed) = (row("dm-2"), row("dm-3"));
        assert_eq!(aimed.release_due.as_deref(), Some("2026-11-10"));
        assert_eq!(aimed.due, None);
        assert_eq!(plain.release_due, None);
        assert!(aimed.rank < plain.rank, "{} vs {}", aimed.rank, plain.rank);
        // The feed's rank is the sweep's ordering rank, aim included, not the own-tags rank
        // pinning reads.
        let aim = crate::rank::Aim::of(&dir);
        assert_eq!(
            aimed.rank,
            crate::rank::aimed(&aimed.raw, today, aim.as_ref()).key()
        );
        assert_ne!(aimed.rank, crate::rank::of(&aimed.raw, today).key());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Done lists finished work, newest first: the sheets' `### Done` by default, and with a
    // window the rows rolled into `agent/versions/` too. A dropped row is not finished work.
    #[test]
    fn done_reads_the_sheets_and_with_a_window_the_rolled_rows() {
        let dir = sheet(
            "feeddone",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n- [ ] open\n\n---\n### Done\n\
             - [x] shipped <!-- id:dm-1 done:2026-11-08 pr:63 -->\n\
             - [x] gone <!-- id:dm-2 done:2026-11-08 dropped: no -->\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\n\n## Tasks\n- [ ] \n\n---\n### Done\n\
             - [x] agent fix <!-- id:dm-3 done:2026-11-09 pr:70 -->\n",
        );
        std::fs::create_dir_all(dir.join("agent/versions")).unwrap();
        std::fs::write(
            dir.join("agent/versions/v0.3.0.md"),
            "# v0.3.0\n\n## Done rows\n\
             - [x] rolled <!-- id:dm-4 done:2026-11-01 pr:50 -->\n\
             - [x] ancient <!-- id:dm-5 done:2026-09-01 pr:9 -->\n\n\
             ## Sheet done rows\n- [x] human rolled <!-- id:dm-6 done:2026-11-02 -->\n",
        )
        .unwrap();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 9).unwrap();
        let ids = |rows: Vec<FeedRow>| -> Vec<(String, &'static str)> {
            rows.into_iter()
                .map(|r| (r.id.unwrap_or_default(), r.lane))
                .collect()
        };
        let sheet_only = done_for_dir("bnb", "demo", &dir, today, None);
        assert_eq!(sheet_only[0].section, Some("done"));
        assert_eq!(sheet_only[0].state, "done");
        assert_eq!(sheet_only[0].prs, ["70"]);
        assert_eq!(
            ids(sheet_only),
            [("dm-3".into(), "agent"), ("dm-1".into(), "human")]
        );
        assert_eq!(
            ids(done_for_dir("bnb", "demo", &dir, today, Some(14))),
            [
                ("dm-3".into(), "agent"),
                ("dm-1".into(), "human"),
                ("dm-6".into(), "human"),
                ("dm-4".into(), "agent"),
            ],
            "the window reads the rolled rows and leaves the ancient one out"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A row's details are the indented lines under it, read by the sheet parser, so a reader of
    // the feed never re-parses the sheet; a row with nothing under it carries none.
    #[test]
    fn the_feed_carries_each_rows_details() {
        let dir = sheet("feeddetails", "# demo\n\n## Tasks\n- [ ] bare\n");
        write_agent_sheet(
            &dir,
            "# demo - agent board\n\n## Tasks\n\
             - [ ] planned one <!-- id:dm-1 -->\n  goal: it works\n  check: a test\n\
             - [ ] bare one <!-- id:dm-2 -->\n",
        );
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let (_, rows) = feed_for_dir("bnb", "demo", &dir, today);
        let got: Vec<(&str, Vec<String>)> = rows
            .iter()
            .map(|r| (r.text.as_str(), r.details.clone()))
            .collect();
        assert_eq!(
            got,
            [
                ("bare", vec![]),
                (
                    "planned one",
                    vec!["goal: it works".to_string(), "check: a test".to_string()]
                ),
                ("bare one", vec![]),
            ]
        );
        let v = serde_json::to_value(&rows[1]).unwrap();
        assert_eq!(v["details"][0], "goal: it works");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Focus rows ride the same shape with no project; only the Focus section is read, so a
    // task elsewhere in the note (a Log checklist) is not on the board.
    #[test]
    fn focus_rows_are_the_open_focus_tasks_with_no_project() {
        let dir = sheet("focus", "unused\n");
        let note = dir.join("2026-11-04.md");
        std::fs::write(
            &note,
            "# 2026-11-04\n\n## Focus\n- [ ] board ui #urgent\n- [x] done one\n- [/] going\n\n\
             ## Log\n- [ ] not focus\n",
        )
        .unwrap();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let rows = focus_rows("personal", &note, today);
        let got: Vec<(&str, &str, Option<&str>, usize)> = rows
            .iter()
            .map(|r| (r.lane, r.text.as_str(), r.project.as_deref(), r.line))
            .collect();
        assert_eq!(
            got,
            [("focus", "board ui", None, 4), ("focus", "going", None, 6)]
        );
        assert_eq!(rows[0].priority, "urgent");
        assert!(focus_rows("personal", &dir.join("absent.md"), today).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_with_no_sheet_is_still_in_the_feed_with_no_rows() {
        let dir = sheet("feedbare", "# prose only\n");
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 4).unwrap();
        let (proj, rows) = feed_for_dir("personal", "bare", &dir, today);
        assert!(rows.is_empty());
        assert_eq!((proj.version, proj.open), (None, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn agent_rows_are_empty_for_a_project_with_no_agent_work() {
        // Empty is a valid answer, and must be empty rather than absent-or-error: the
        // preflight prints nothing and moves on.
        let dir = sheet("quiet", "# d\nVersion: v1\n\n## Tasks\n- [ ] only mine\n");
        assert!(agent_rows_for_dir("d", &dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn agent_rows_are_empty_for_a_dir_with_no_sheet_at_all() {
        let dir = sheet("nosheet", "# prose only\n");
        std::fs::remove_file(dir.join("README.md")).unwrap();
        std::fs::write(dir.join("summary.md"), "# prose only, no tasks\n").unwrap();
        assert!(agent_rows_for_dir("d", &dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dir_with_no_sheet_is_skipped_not_rendered_empty() {
        let dir = std::env::temp_dir().join(format!("notes-board-n-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("summary.md"), "# prose only, no tasks\n").unwrap();
        assert!(project_block("nosheet", &dir, Lane::Human).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- layout: order, fold, links, case ------------------------------------------------

    #[test]
    fn listed_profiles_lead_and_the_rest_still_follow() {
        let layout = config::BoardLayout {
            order: vec!["biz".into(), "personal".into()],
            full: vec![],
        };
        let got = layout.sort(vec![
            "biz".to_string(),
            "acmecorp".to_string(),
            "personal".to_string(),
        ]);
        assert_eq!(got, vec!["biz", "personal", "acmecorp"]);
    }

    #[test]
    fn an_unlisted_profile_is_never_dropped() {
        // The whole reason `order` appends rather than filters: an org missing from a
        // hand-edited config must still show its work, or the board silently loses a job.
        let layout = config::BoardLayout {
            order: vec!["biz".into()],
            full: vec![],
        };
        assert_eq!(
            layout.sort(vec![
                "aaa".to_string(),
                "biz".to_string(),
                "zzz".to_string()
            ]),
            vec!["biz", "aaa", "zzz"]
        );
    }

    #[test]
    fn a_name_in_order_that_is_not_a_profile_is_ignored_not_fatal() {
        let layout = config::BoardLayout {
            order: vec!["typo".into(), "biz".into()],
            full: vec![],
        };
        assert_eq!(layout.sort(vec!["biz".to_string()]), vec!["biz"]);
    }

    #[test]
    fn an_empty_full_list_means_every_profile_renders_full() {
        // Opt-in: a machine that never writes `[board_layout]` must see the old board.
        let layout = config::BoardLayout::default();
        assert!(layout.is_full("personal"));
        assert!(layout.is_full("anything"));
    }

    #[test]
    fn naming_one_profile_full_folds_the_others() {
        let layout = config::BoardLayout {
            order: vec![],
            full: vec!["biz".into()],
        };
        assert!(layout.is_full("biz"));
        assert!(!layout.is_full("personal"));
    }

    #[test]
    fn a_rollup_line_is_one_line_with_the_counts_and_the_agent_lane_next() {
        let dir = sheet(
            "folded",
            "# folded\nVersion: v0.0.1\n\n## Tasks\n\
             - [ ] a human item\n- [x] shipped\n",
        );
        write_agent_sheet(
            &dir,
            "# folded - agent board\nVersion: v0.0.1\n\n## Tasks\n\
             - [ ] a backlog row first <!-- tier:backlog -->\n\
             - [ ] push nightly-sync dedup fix\n",
        );
        let l = project_rollup_line("folded", &dir, Lane::Human).unwrap();

        assert_eq!(l.lines().count(), 1, "a rollup must stay one line:\n{l}");
        assert!(!l.contains("- [ ]"), "no checkboxes in a rollup:\n{l}");
        assert!(l.contains("v0.0.1 - 1 open"), "{l}");
        assert!(l.contains("next: a human item"), "{l}");
        assert!(
            !l.contains("nightly-sync"),
            "the agent sheet is a different file:\n{l}"
        );

        // and the same project on the agent board shows what it left in flight
        let a = project_rollup_line("folded", &dir, Lane::Agent).unwrap();
        assert!(
            a.contains("v0.0.1 - Today 1 | Backlog 1 | Epics 0 | Epic backlog 0"),
            "{a}"
        );
        assert!(
            a.contains("next: push nightly-sync dedup fix"),
            "next is a board row, never the backlog:\n{a}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_playtest_checks_are_one_counted_line_on_the_human_board_only() {
        let dir = sheet(
            "playtest",
            "# game\nVersion: v0.1.0\n\n## Tasks\n- [ ] a sheet row\n",
        );
        std::fs::write(
            crate::playtest::path(&dir),
            "# Playtest\n\n## General\n- [ ] lobby: two pads join\n- [x] title: fades\n\n\
             ## Dodgeball\n- [ ] arena: ball never clips\n- [ ] menu: back exits\n",
        )
        .unwrap();

        let vault = dir.parent().unwrap();
        let name = dir.file_name().unwrap().to_str().unwrap();
        assert_eq!(
            playtest_line_for(&dir, vault).unwrap(),
            format!("- 3 playtest checks waiting -> [[{name}/playtest|playtest.md]]\n")
        );

        let b = project_block("game", &dir, Lane::Human).unwrap();
        assert_eq!(b.matches("playtest check").count(), 1, "{b}");
        assert!(b.contains("3 playtest checks waiting -> "), "{b}");
        assert!(
            !b.contains("lobby") && !b.contains("arena"),
            "never the rows:\n{b}"
        );
        let r = project_rollup_line("game", &dir, Lane::Human).unwrap();
        assert!(r.contains("\n  - 3 playtest checks waiting -> "), "{r}");
        write_agent_sheet(
            &dir,
            "# game - agent board\nVersion: v0.1.0\n\n## Tasks\n- [ ] sub\n",
        );
        let a = project_block("game", &dir, Lane::Agent).unwrap();
        assert!(!a.contains("playtest"), "{a}");

        // every check ticked: no line at all
        std::fs::write(
            crate::playtest::path(&dir),
            "# Playtest\n\n## General\n- [x] done\n",
        )
        .unwrap();
        assert!(playtest_line_for(&dir, vault).is_none());
        assert!(!project_block("game", &dir, Lane::Human)
            .unwrap()
            .contains("playtest"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rollup_falls_back_to_the_human_lane_when_there_is_no_agent_row() {
        let dir = sheet(
            "humanonly",
            "# humanonly\nVersion: v1.0.0\n\n## Tasks\n- [ ] only mine\n",
        );
        let l = project_rollup_line("humanonly", &dir, Lane::Human).unwrap();
        assert!(l.contains("next: only mine"), "{l}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_list_rolls_up_without_a_next() {
        let dir = sheet("idle", "# idle\nVersion: v0.1.0\n\n## Tasks\n");
        let l = project_rollup_line("idle", &dir, Lane::Human).unwrap();
        assert!(l.contains("0 open"), "{l}");
        assert!(!l.contains("next:"), "nothing to point at:\n{l}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rollup_needs_a_sheet_like_a_block_does() {
        let dir = sheet("notasks", "# prose\n");
        assert!(project_rollup_line("notasks", &dir, Lane::Human).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_long_next_truncates_on_a_word_boundary() {
        let long = "root cause of the runtime fixes never taking effect because the published \
                    runtime was built from an abandoned integration line";
        let got = truncate_words(long, 60);
        assert!(got.chars().count() <= 63, "{got}");
        assert!(got.ends_with("..."), "{got}");
        // Never mid-word: every word kept must be a whole word from the source.
        let kept = got.trim_end_matches("...").trim();
        for w in kept.split_whitespace() {
            assert!(long.split_whitespace().any(|s| s == w), "cut mid-word: {w}");
        }
    }

    #[test]
    fn a_single_oversized_word_is_still_shown() {
        let got = truncate_words(&"x".repeat(200), 10);
        assert!(got.starts_with("xxxxxxxxxx"), "{got}");
        assert!(got.ends_with("..."), "{got}");
    }

    #[test]
    fn the_pre_rename_board_is_retired_once_its_replacement_exists() {
        let dir = sheet("retire", "# d\nVersion: v1\n\n## Tasks\n- [ ] x\n");
        let agent = dir.join("agent-board.md");
        let legacy = dir.join("ai-board.md");
        std::fs::write(&agent, "---\nid: agent-board\n---\n").unwrap();
        std::fs::write(
            &legacy,
            "---\nid: ai-board\ntags: [board]\n---\n\n# AI board\n",
        )
        .unwrap();

        retire_ai_board(&Logger::new(dir.join("test.log"), false), &agent);
        assert!(!legacy.exists(), "the stale board is gone");
        assert!(agent.exists(), "its replacement is untouched");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // THE NEGATIVE CONTROL. `ai-board.md` is a plausible name for something the human wrote
    // by hand; only a file carrying the generator's own `id:` may be removed.
    #[test]
    fn a_hand_written_file_of_the_same_name_is_never_removed() {
        let dir = sheet("keep", "# d\nVersion: v1\n\n## Tasks\n- [ ] x\n");
        let agent = dir.join("agent-board.md");
        let mine = dir.join("ai-board.md");
        std::fs::write(&agent, "---\nid: agent-board\n---\n").unwrap();
        std::fs::write(&mine, "# my notes on the ai board idea\nkeep me\n").unwrap();

        retire_ai_board(&Logger::new(dir.join("test.log"), false), &agent);
        assert_eq!(
            std::fs::read_to_string(&mine).unwrap(),
            "# my notes on the ai board idea\nkeep me\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn retiring_is_a_no_op_when_there_is_nothing_to_retire() {
        let dir = sheet("noop", "# d\nVersion: v1\n\n## Tasks\n- [ ] x\n");
        let agent = dir.join("agent-board.md");
        std::fs::write(&agent, "---\nid: agent-board\n---\n").unwrap();
        retire_ai_board(&Logger::new(dir.join("test.log"), false), &agent); // must not panic on a missing file
        assert!(agent.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_board_row_keeps_the_case_the_human_typed() {
        // `task_key` lower-cases because it is a de-dup key; a display row must not.
        assert_eq!(
            render("- [ ] Fix PR #423 on Staging"),
            "Fix PR #423 on Staging"
        );
        assert_eq!(
            render("- [ ] Ship WidgetCo v1.13.0"),
            "Ship WidgetCo v1.13.0"
        );
    }

    #[test]
    fn task_key_still_folds_case_for_matching() {
        // `ptask done "<query>"` resolves through `task_key`; case-folding it is the point.
        assert_eq!(md::task_key("- [ ] Fix PR #423"), "fix pr #423");
        assert_eq!(
            md::task_key("- [x] Fix PR #423"),
            md::task_key("- [ ] fix pr #423")
        );
    }

    #[test]
    fn a_temp_dir_outside_the_vault_links_nothing_rather_than_dangling() {
        // `linked_name` must never emit a wikilink it cannot resolve. A sheet outside the
        // vault has no vault-relative address, so the heading stays a plain name.
        let dir = sheet(
            "outside",
            "# outside\nVersion: v0.1.0\n\n## Tasks\n- [ ] x\n",
        );
        let got = linked_name("outside", &dir);
        assert_eq!(got, "outside", "expected no link for an out-of-vault sheet");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sheet_inside_the_vault_links_vault_relative() {
        // Vault-relative, NOT profile-root-relative: a root-relative target resolves only
        // for `personal` (whose root IS the vault) and dangles for every other org - the
        // failure `board_path` documents. bnb is the case that proves it.
        let vault = std::path::Path::new("/vault");
        assert_eq!(
            link_for(
                "widgetco",
                vault,
                Some(std::path::Path::new(
                    "/vault/lab/biz/projects/current/widgetco/README.md"
                ))
            ),
            "[[lab/biz/projects/current/widgetco/README|widgetco]]"
        );
        assert_eq!(
            link_for(
                "agent-runtime",
                vault,
                Some(std::path::Path::new(
                    "/vault/lab/projects/current/agent-runtime/README.md"
                ))
            ),
            "[[lab/projects/current/agent-runtime/README|agent-runtime]]"
        );
    }

    #[test]
    fn a_sheet_outside_the_vault_is_never_linked() {
        // A dangling wikilink is worse than a plain heading, so the guard fails closed.
        let vault = std::path::Path::new("/vault");
        assert_eq!(
            link_for(
                "stray",
                vault,
                Some(std::path::Path::new("/tmp/x/README.md"))
            ),
            "stray"
        );
        assert_eq!(link_for("nosheet", vault, None), "nosheet");
    }

    #[test]
    fn a_project_is_named_as_a_whole_word() {
        assert!(names_word("release: cut app today", "app"));
        assert!(names_word(
            "cut unity-core-playground",
            "unity-core-playground"
        ));
        assert!(!names_word("cut apple games", "app"));
        assert!(!names_word("cut my-app", "app"));
    }

    // The window's build state is its cut row's: a release row naming the project, gated in the
    // window, nearest the due day. A far-off release (a festival demo) is another release.
    #[test]
    fn a_window_reads_its_build_off_its_cut_row() {
        let dir = sheet(
            "feed-cut",
            "# demo\nVersion: v0.3.0\n\n## Tasks\n- [ ] other\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Tasks\n\
             - [ ] release(steam): cut games 14:00 #at/2026-11-19/1400\n\
             - [ ] release(deploy): festival demo for demo #at/2026-12-15/0900\n\
             - [ ] release(steam): cut other games #at/2026-11-19/1400\n",
        );
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        let (fp, rows) = feed_for_dir("bnb", "demo", &dir, today);
        let frame = crate::window::Frame {
            opened: chrono::NaiveDate::from_ymd_opt(2026, 11, 12).unwrap(),
            due: Some(today),
            locked: None,
            cut: None,
            start: None,
            queued: false,
            carried: None,
        };
        let at = |h| today.and_hms_opt(h, 0, 0).unwrap();
        let build = |now, rows: &[FeedRow], done: &[FeedRow]| {
            cut_of(&fp, &frame, (rows, done), now).map(|c| (c.at.to_string(), c.build))
        };
        use crate::window::Build;
        // The festival demo is weeks past the due day: not this window's cut.
        let festival: Vec<FeedRow> = rows
            .iter()
            .filter(|r| r.text.contains("festival"))
            .cloned()
            .collect();
        assert_eq!(build(at(9), &festival, &[]), None);
        let own = rows
            .iter()
            .find(|r| r.text.contains("cut games"))
            .unwrap()
            .clone();
        // A row of another project counts only when its text names this one.
        let elsewhere = FeedRow {
            project: Some("elsewhere".into()),
            ..own.clone()
        };
        assert_eq!(build(at(9), &[elsewhere], &[]), None);
        // The project's own row in the window is its cut: held until its time, then queued.
        let cut = |b| Some(("2026-11-19 14:00:00".to_string(), b));
        assert_eq!(
            build(at(9), std::slice::from_ref(&own), &[]),
            cut(Build::Held)
        );
        assert_eq!(
            build(at(15), std::slice::from_ref(&own), &[]),
            cut(Build::Queued)
        );
        let doing = FeedRow {
            state: "doing",
            ..own.clone()
        };
        assert_eq!(build(at(15), &[doing], &[]), cut(Build::Building));
        let closed = FeedRow {
            state: "done",
            ..own.clone()
        };
        assert_eq!(
            build(at(20), &[], std::slice::from_ref(&closed)),
            cut(Build::Built)
        );
        // The previous release's cut, gated the day this window opened, is not this window's.
        let reopened = crate::window::Frame {
            opened: today,
            ..frame
        };
        assert_eq!(
            cut_of(&fp, &reopened, (&[], std::slice::from_ref(&closed)), at(20)).map(|c| c.build),
            None
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
