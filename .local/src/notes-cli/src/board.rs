//! `notes board` - every project's current wave: the queue and the agent sheets, one file each.
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
//! WHY IT CANNOT DISAGREE WITH THE COCKPIT
//!
//! It reads each project's `## Wave` through `project_tasks::open_wave_for_dir` - the same
//! sheet, the same heading resolution and the same open-task predicate that `notes ptask
//! list` and `notes-cockpit.sh` use. There is one list, rendered twice, rather than two
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
use crate::project_tasks;
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

/// The open tasks of `lane`'s current wave for this project.
///
/// The lane names a DIRECTORY, so this is one parser pointed at one of two sheets rather
/// than one sheet split by a tag. A board can no longer hide a row from the human's own
/// list, which is what a filtered human lane did.
fn lane_tasks(dir: &std::path::Path, lane: Lane) -> Option<(String, Vec<String>)> {
    project_tasks::open_wave_for_dir(&lane.dir(dir))
}

/// The `N open` tail both renderers share, so the two counts cannot disagree.
fn counts(open: &[String]) -> String {
    format!("{} open", open.len())
}

/// One project's rendered block, or `None` when it has no task sheet.
fn project_block(name: &str, dir: &std::path::Path, lane: Lane) -> Option<String> {
    let (version, open) = lane_tasks(dir, lane)?;

    let mut s = format!(
        "## {} · {version} — {}\n",
        linked_name(name, &lane.dir(dir)),
        counts(&open)
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
        return Some(s);
    }
    for l in &open {
        s.push_str(&format!("- [ ] {}\n", render(l)));
    }
    Some(s)
}

/// One project as a SINGLE line, for an org that is not the one you are working today.
///
/// The board has to hold every org or it is not a board, and it has to be readable or nobody
/// opens it. One client project contributing 47 multi-sentence rows made the two goals fight;
/// folding the orgs you are not in settles it without hiding anything, because the count is
/// still exact and the name is still a link to the full list.
fn project_rollup_line(name: &str, dir: &std::path::Path, lane: Lane) -> Option<String> {
    let (version, open) = lane_tasks(dir, lane)?;
    if open.is_empty() && lane == Lane::Agent {
        return None; // same rule folded: an idle agent sheet is not worth a row
    }
    let mut s = format!(
        "- {} {version} - {}",
        linked_name(name, &lane.dir(dir)),
        counts(&open)
    );
    let next = open.first().map(|l| render(l));
    if let Some(next) = next {
        s.push_str(&format!(" - next: {}", truncate_words(&next, 60)));
    }
    s.push('\n');
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

/// A wave line as the board shows it: checkbox stripped, HTML comments dropped. Keeps the
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
/// rule `focus::list_all` follows for the cockpit.
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
        Err(e) => log.info("board", &format!("could not retire {}: {e}", legacy.display())),
    }
}

/// Render + write ONE board. Two lanes, one renderer, so `board.md` and `agent-board.md` cannot
/// disagree about what a project's wave holds.
fn write_one(log: &Logger, path: &std::path::Path, lane: Lane) -> Result<PathBuf> {
    let today = Local::now().date_naive().format("%Y-%m-%d");
    let (id, title, blurb) = match lane {
        Lane::Human => (
            "board",
            "Board",
            "_Every project's current `## Wave` — the queue, every open item whoever does \
             it. What the agents are breaking down underneath it is on the \
             [[lab/projects/agent-board|agent board]]. Generated by `notes board` (and each \
             `notes today`) from the same sheets the cockpit reads — edit a task on its \
             project sheet or in the cockpit, never here._",
        ),
        Lane::Agent => (
            "agent-board",
            "Agent board",
            "_Each project's `agent/README.md` — the agents' working board: the subtasks and \
             state under a queue row, so an interrupted wave can be picked up. The queue \
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
/// this project, so a fresh session can pick a wave up rather than restart it.
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
/// profile tree. Returns `<project>\t<text>` rows from the agent sheet's current wave.
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
            "# demo\nVersion: v0.3.0\n\n## Wave: v0.3.0 (current)\n\
             - [ ] human task\n- [ ] tagged but still mine #ai\n- [x] done one\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Wave: v0.3.0 (current)\n\
             - [ ] agent subtask\n",
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
        assert!(agent.contains("## demo · v0.3.0 — 1 open\n"), "{agent}");
        assert!(agent.contains("- [ ] agent subtask"), "{agent}");
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
            "# idlebot\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] mine only\n",
        );
        write_agent_sheet(
            &dir,
            "# idlebot - agent board\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] \n",
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
            "# bare\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] mine only\n",
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
            "# aidkit\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] restock #aid kit\n",
        );
        write_agent_sheet(
            &dir,
            "# aidkit - agent board\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n\
             - [ ] audit the #aid inventory\n",
        );
        let h = project_block("aidkit", &dir, Lane::Human).unwrap();
        assert!(h.contains("restock #aid kit"), "{h}");
        let a = project_block("aidkit", &dir, Lane::Agent).unwrap();
        assert!(a.contains("audit the #aid inventory"), "{a}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_wave_still_renders_the_project() {
        let dir = std::env::temp_dir().join(format!("notes-board-e-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A sheet whose only row is the scaffold placeholder is EMPTY, not one item.
        std::fs::write(
            dir.join("README.md"),
            "# quiet\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] \n",
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
            "# demo\nVersion: v0.3.0\n\n## Wave: v0.3.0 (current)\n- [ ] human task\n",
        );
        write_agent_sheet(
            &dir,
            "# demo - agent board\nVersion: v0.3.0\n\n## Wave: v0.3.0 (current)\n\
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
        let dir = sheet(
            "wire",
            "# d\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] only mine\n",
        );
        write_agent_sheet(
            &dir,
            "# d - agent board\nVersion: v1\n\n## Wave: v1 (current)\n\
             - [ ] a thing #high <!-- pr:1218 -->\n",
        );
        let rows = agent_rows_for_dir("d", &dir);
        assert_eq!(rows, vec!["d\ta thing".to_string()]);
        assert_eq!(rows[0].split('\t').count(), 2, "{rows:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn agent_rows_are_empty_for_a_project_with_no_agent_work() {
        // Empty is a valid answer, and must be empty rather than absent-or-error: the
        // preflight prints nothing and moves on.
        let dir = sheet(
            "quiet",
            "# d\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] only mine\n",
        );
        assert!(agent_rows_for_dir("d", &dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn agent_rows_are_empty_for_a_dir_with_no_sheet_at_all() {
        let dir = sheet("nosheet", "# prose only\n");
        std::fs::remove_file(dir.join("README.md")).unwrap();
        std::fs::write(dir.join("summary.md"), "# prose only, no wave\n").unwrap();
        assert!(agent_rows_for_dir("d", &dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dir_with_no_sheet_is_skipped_not_rendered_empty() {
        let dir = std::env::temp_dir().join(format!("notes-board-n-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("summary.md"), "# prose only, no wave\n").unwrap();
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
            "# folded\nVersion: v0.0.1\n\n## Wave: v0.0.1 (current)\n\
             - [ ] a human item\n- [x] shipped\n",
        );
        write_agent_sheet(
            &dir,
            "# folded - agent board\nVersion: v0.0.1\n\n## Wave: v0.0.1 (current)\n\
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
        assert!(a.contains("v0.0.1 - 1 open"), "{a}");
        assert!(a.contains("next: push nightly-sync dedup fix"), "{a}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rollup_falls_back_to_the_human_lane_when_there_is_no_agent_row() {
        let dir = sheet(
            "humanonly",
            "# humanonly\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n- [ ] only mine\n",
        );
        let l = project_rollup_line("humanonly", &dir, Lane::Human).unwrap();
        assert!(l.contains("next: only mine"), "{l}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_wave_rolls_up_without_a_next() {
        let dir = sheet(
            "idle",
            "# idle\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n",
        );
        let l = project_rollup_line("idle", &dir, Lane::Human).unwrap();
        assert!(l.contains("0 open"), "{l}");
        assert!(!l.contains("next:"), "nothing to point at:\n{l}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rollup_needs_a_sheet_like_a_block_does() {
        let dir = sheet("nowave", "# prose\n");
        assert!(project_rollup_line("nowave", &dir, Lane::Human).is_none());
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
        let dir = sheet("retire", "# d\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] x\n");
        let agent = dir.join("agent-board.md");
        let legacy = dir.join("ai-board.md");
        std::fs::write(&agent, "---\nid: agent-board\n---\n").unwrap();
        std::fs::write(&legacy, "---\nid: ai-board\ntags: [board]\n---\n\n# AI board\n").unwrap();

        retire_ai_board(&Logger::new(dir.join("test.log"), false), &agent);
        assert!(!legacy.exists(), "the stale board is gone");
        assert!(agent.exists(), "its replacement is untouched");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // THE NEGATIVE CONTROL. `ai-board.md` is a plausible name for something the human wrote
    // by hand; only a file carrying the generator's own `id:` may be removed.
    #[test]
    fn a_hand_written_file_of_the_same_name_is_never_removed() {
        let dir = sheet("keep", "# d\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] x\n");
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
        let dir = sheet("noop", "# d\nVersion: v1\n\n## Wave: v1 (current)\n- [ ] x\n");
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
            "# outside\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] x\n",
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
}
