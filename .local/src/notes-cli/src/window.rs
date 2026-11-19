//! Release windows (`stages.md`, "Release windows"): the rows a version commits to when it
//! opens, the interrupt lane that is the only way into a focus project's open window, and the
//! score its cut writes into the frozen note.
//!
//! The snapshot is a `## Committed` section in the open version's agent note
//! (`agent/versions/<vX.Y.Z>.md`): one line per row with the row's id kept, under a head marker
//! with the day the window opened and the day it is due. The cut reads it back to count what
//! was delivered, carried, dropped and interrupted. Nothing else is stored: carried is the
//! committed rows still open at the cut (the rows `carry_open` stamps `carried:N`) or deferred
//! to a later version.

use crate::epics::Index;
use crate::md;
use crate::project_sweep;
use crate::project_tasks;
use crate::projects;
use crate::sheet::{self, V};
use anyhow::Result;
use chrono::NaiveDate;
use std::collections::HashSet;
use std::fs;
use std::path::Path;

/// The agent note section holding a window's committed rows.
const COMMITTED: &str = "Committed";
/// The frozen note section holding a window's score.
const WINDOW: &str = "Window";
/// The tag a row carries when it entered a frozen window after it opened.
const INTERRUPT: &str = "#interrupt";
const HEAD: &str = "<!-- window:";
/// Closes the committed rows, so a line added under them later is not read as committed.
const END: &str = "<!-- /window -->";

/// A row's identity across both lanes and the agent note: its id, else its text key.
fn key(line: &str) -> String {
    md::row_id(line).unwrap_or_else(|| md::task_key(&md::drop_tag(line, INTERRUPT)))
}

/// The key of a `## Committed` line (`- <text> <!-- id:x -->`), read as the row it was.
fn snapshot_key(line: &str) -> Option<String> {
    let rest = line.trim().strip_prefix("- ")?;
    Some(key(&format!("- [ ] {rest}")))
}

fn has_interrupt(line: &str) -> bool {
    md::find_hashtags(line).iter().any(|t| t == "interrupt")
}

/// Is `line` in the window `keys` holds: one of its committed rows, or a row that entered through
/// the interrupt lane. The rows the agent board's Sprint tier keeps (`project_sweep::tier`).
pub(crate) fn holds(keys: &HashSet<String>, line: &str) -> bool {
    has_interrupt(line) || keys.contains(&key(line))
}

/// What a window committed to, read back from its agent note.
#[derive(Debug)]
pub(crate) struct Snapshot {
    pub opened: NaiveDate,
    pub due: Option<NaiveDate>,
    pub keys: HashSet<String>,
}

/// The rows of version `cur` in one project: open and closed, both lanes plus the rows the
/// Done window already rolled into the agent note. Untagged epics span releases, so they are
/// never committed or counted (`gated_rows`).
#[derive(Debug, Default)]
pub(crate) struct Rows {
    pub open: Vec<String>,
    /// How many of `open`, from the front, are the project's own (human) sheet's rows.
    pub human: usize,
    pub closed: Vec<String>,
    /// Open rows aimed at a later version: a committed row deferred there was carried.
    pub later: Vec<String>,
}

fn rows_of(dir: &Path, cur: V, ix: &Index) -> Rows {
    let mut r = Rows::default();
    for (i, lane) in [dir.to_path_buf(), projects::agent_dir(dir)]
        .iter()
        .enumerate()
    {
        let content = project_tasks::task_sheet(lane)
            .and_then(|p| fs::read_to_string(p).ok())
            .unwrap_or_default();
        r.open.extend(
            sheet::current_rows(&content, Some(cur))
                .into_iter()
                .map(|(_, l)| l.to_string())
                .filter(|l| ix.counts(l)),
        );
        if i == 0 {
            r.human = r.open.len();
        }
        let lines: Vec<&str> = content.lines().collect();
        r.later.extend(
            lines
                .iter()
                .filter(|l| md::is_open_task(l) && sheet::is_later(l, Some(cur)))
                .map(|l| l.to_string()),
        );
        r.closed.extend(
            project_tasks::done_rows_of(&content, Some(cur))
                .into_iter()
                .map(|rg| lines[rg.start].to_string()),
        );
    }
    let note = fs::read_to_string(projects::agent_note_path(dir, &projects::fmt_version(cur)))
        .unwrap_or_default();
    r.closed.extend(project_tasks::note_done_rows(&note));
    r.closed.retain(|l| ix.counts(l));
    r.later.retain(|l| ix.counts(l));
    r
}

/// The `## Committed` section for `open`: the head marker, then one line per row, and how many.
fn section(open: &[String], opened: NaiveDate, due: Option<NaiveDate>) -> (String, usize) {
    let due = due.map_or_else(|| "-".to_string(), |d| d.to_string());
    let mut seen = HashSet::new();
    let rows: Vec<String> = open
        .iter()
        .filter(|l| seen.insert(key(l)))
        .map(|l| {
            let line = format!("- {}", md::task_text(l));
            match md::row_id(l) {
                Some(id) => md::add_marker(&line, &format!("id:{id}")),
                None => line,
            }
        })
        .collect();
    let body = format!(
        "## {COMMITTED}\n{HEAD} opened={opened} due={due} -->\n{}{END}\n",
        rows.iter().map(|r| format!("{r}\n")).collect::<String>()
    );
    (body, rows.len())
}

/// Record the rows version `cur` commits to in its agent note, once. Returns how many, or
/// `None` when the window already has its snapshot: a window opens once, and a second
/// snapshot would quietly count mid-window adds as committed.
///
/// A window commits only what fits it. The agent lane fills its [`capacity`] the way the agent
/// board fills (`project_sweep::fit`: pinned rows, then `#requested`, then sheet order, at least
/// the board floor); the human lane has no measured pace, so only its pinned rows (in progress,
/// `#urgent`, due soon) go in. The rest stay open on the version uncommitted, so the score counts
/// the sprint and not the whole backlog, and the cut carries them as it carries every open row.
pub(crate) fn record(
    dir: &Path,
    project: &str,
    cur: V,
    opened: NaiveDate,
    due: Option<NaiveDate>,
    ix: &Index,
) -> Result<Option<usize>> {
    if read(dir, cur).is_some() {
        return Ok(None);
    }
    // One slot per row: a row on both sheets is the agent board's, which the capacity measures.
    let rows = rows_of(dir, cur, ix);
    let (human, agent) = rows.open.split_at(rows.human);
    let mut seen = HashSet::new();
    let agent: Vec<&str> = agent
        .iter()
        .filter(|l| seen.insert(key(l)))
        .map(String::as_str)
        .collect();
    let human: Vec<&str> = human
        .iter()
        .filter(|l| seen.insert(key(l)))
        .map(String::as_str)
        .collect();
    let fitted = |lines: &[&str], budget: u32, floor: usize| -> Vec<String> {
        let fits = project_sweep::fit(lines, budget, floor, opened, Some(cur));
        lines
            .iter()
            .zip(fits)
            .filter(|&(_, f)| f)
            .map(|(l, _)| l.to_string())
            .collect()
    };
    let floor = crate::config::sheet_shape().agent_board_floor;
    let mut committed = fitted(&human, 0, 0);
    committed.extend(fitted(&agent, capacity(dir, opened, due), floor));
    let path = projects::ensure_agent_note(dir, project, &projects::fmt_version(cur))?;
    let note = fs::read_to_string(&path)?;
    let (body, n) = section(&committed, opened, due);
    md::write_atomic(&path, &format!("{}\n\n{body}", note.trim_end()))?;
    Ok(Some(n))
}

/// The weight a window opened on `opened` and due on `due` can deliver: the agent lane's shipped
/// weight scaled to [`span_days`]. Zero with no shipping history, when only pinned rows and the
/// board floor are committed.
pub(crate) fn capacity(dir: &Path, opened: NaiveDate, due: Option<NaiveDate>) -> u32 {
    project_tasks::board_budget(dir, span_days(opened, due, projects::cadence_of(dir)))
}

/// The days a window runs, which its capacity is measured in: opened to due, at least one, or
/// the stage's cadence when it has no due day.
fn span_days(opened: NaiveDate, due: Option<NaiveDate>, cadence: i64) -> u32 {
    let days = due.map_or(cadence, |d| (d - opened).num_days().max(1));
    u32::try_from(days).unwrap_or(0)
}

/// The day an open window is due: the cadence's day after the last cut, or the human's target
/// day for this version when that comes first (a window cut early for a promised build).
pub(crate) fn due_on(
    last_cut: Option<NaiveDate>,
    cadence: i64,
    cur: V,
    target: Option<(V, NaiveDate)>,
) -> Option<NaiveDate> {
    let by_cadence = last_cut.map(|d| d + chrono::Duration::days(cadence));
    let by_target = target.filter(|(v, _)| *v == cur).map(|(_, d)| d);
    match (by_cadence, by_target) {
        (Some(c), Some(t)) => Some(c.min(t)),
        (c, t) => t.or(c),
    }
}

/// The snapshot of version `cur`, `None` when its window was never recorded.
pub(crate) fn read(dir: &Path, cur: V) -> Option<Snapshot> {
    let note =
        fs::read_to_string(projects::agent_note_path(dir, &projects::fmt_version(cur))).ok()?;
    let lines: Vec<&str> = note.lines().collect();
    let span = md::section_span(&lines, COMMITTED)?;
    let body = &lines[span];
    let at = body.iter().position(|l| l.trim_start().starts_with(HEAD))?;
    let head = body[at];
    let field = |k: &str| {
        md::marker_token(head, k).and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
    };
    Some(Snapshot {
        opened: field("opened=")?,
        due: field("due="),
        keys: body[at + 1..]
            .iter()
            .take_while(|l| l.trim() != END)
            .filter_map(|l| snapshot_key(l))
            .collect(),
    })
}

/// The window's counts. At a cut, `open` is what was carried.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub(crate) struct Tally {
    pub committed: usize,
    pub delivered: usize,
    pub open: usize,
    /// Committed rows closed as dropped or duplicate, or gone from both lanes.
    pub dropped: usize,
    /// Rows tagged `#interrupt` in the version that the snapshot does not hold.
    pub interrupted: usize,
}

fn tally(snap: &Snapshot, rows: &Rows) -> Tally {
    let shipped: HashSet<String> = rows
        .closed
        .iter()
        .filter(|l| !md::is_dropped(l))
        .map(|l| key(l))
        .collect();
    let open: HashSet<String> = rows
        .open
        .iter()
        .chain(&rows.later)
        .map(|l| key(l))
        .collect();
    let interrupted: HashSet<String> = rows
        .open
        .iter()
        .chain(rows.closed.iter().filter(|l| !md::is_dropped(l)))
        .filter(|l| has_interrupt(l))
        .map(|l| key(l))
        .filter(|k| !snap.keys.contains(k))
        .collect();
    let delivered = snap.keys.iter().filter(|k| shipped.contains(*k)).count();
    let still = snap
        .keys
        .iter()
        .filter(|k| !shipped.contains(*k) && open.contains(*k))
        .count();
    Tally {
        committed: snap.keys.len(),
        delivered,
        open: still,
        dropped: snap.keys.len() - delivered - still,
        interrupted: interrupted.len(),
    }
}

/// How a cut on `cut` stands against `day`: `ok` on or before it, else `late` and the days.
fn slip(cut: NaiveDate, day: NaiveDate, late: &str, ok: &str) -> String {
    match (cut - day).num_days() {
        n if n > 0 => format!("{late} {n} day{}", if n == 1 { "" } else { "s" }),
        _ => ok.to_string(),
    }
}

/// The score a cut writes: the counts, then the window's due day and the human's target
/// (when one was promised for this version) against the day it was cut.
fn cut_line(snap: &Snapshot, t: &Tally, cut: NaiveDate, target: Option<(V, NaiveDate)>) -> String {
    let mut line = format!(
        "committed {}, delivered {}, carried {}, dropped {}, interrupted {}; opened {}",
        t.committed, t.delivered, t.open, t.dropped, t.interrupted, snap.opened
    );
    match snap.due {
        Some(due) => line.push_str(&format!(
            ", due {due}, cut {cut} ({})",
            slip(cut, due, "late by", "on time")
        )),
        None => line.push_str(&format!(", cut {cut}")),
    }
    if let Some((v, on)) = target {
        line.push_str(&format!(
            "; target {} {on} {}",
            projects::fmt_version(v),
            slip(cut, on, "missed by", "met")
        ));
    }
    line
}

/// The `## Window` section a cut of version `cur` on `cut` writes into its frozen note, empty
/// when the window was never recorded. Read before the cut moves a row.
pub(crate) fn cut_section(
    dir: &Path,
    cur: V,
    ix: &Index,
    cut: NaiveDate,
    target: Option<(V, NaiveDate)>,
) -> String {
    read(dir, cur).map_or_else(String::new, |snap| {
        let line = cut_line(&snap, &tally(&snap, &rows_of(dir, cur, ix)), cut, target);
        format!("\n## {WINDOW}\n{line}\n")
    })
}

/// The `## Window` line of a frozen note, `None` when its version had no snapshot.
pub(crate) fn frozen_line(note: &str) -> Option<String> {
    md::section_text(note, WINDOW).and_then(|t| t.lines().next().map(str::to_string))
}

/// The open window as `--stats --json` emits it.
#[derive(Debug, serde::Serialize)]
pub(crate) struct OpenWindow {
    pub version: String,
    pub opened: String,
    pub due: Option<String>,
    #[serde(flatten)]
    pub tally: Tally,
}

/// The open version's window counted so far, `None` when it has no snapshot.
pub(crate) fn open(dir: &Path, cur: V, ix: &Index) -> Option<OpenWindow> {
    let snap = read(dir, cur)?;
    Some(OpenWindow {
        version: projects::fmt_version(cur),
        opened: snap.opened.to_string(),
        due: snap.due.map(|d| d.to_string()),
        tally: tally(&snap, &rows_of(dir, cur, ix)),
    })
}

/// The Sprint count of an open window: its rows still open in the version, of the rows it holds.
/// `committed` is the snapshot plus every interrupt that entered it, so `open` goes down as a row
/// closes and both go up only when an interrupt enters.
#[derive(Debug, Default, Clone, Copy, PartialEq, serde::Serialize)]
pub(crate) struct Sprint {
    pub open: usize,
    pub committed: usize,
}

impl std::ops::AddAssign for Sprint {
    fn add_assign(&mut self, o: Sprint) {
        self.open += o.open;
        self.committed += o.committed;
    }
}

/// Version `cur`'s [`Sprint`] in project `dir`, `None` when its window was never recorded.
pub(crate) fn sprint(dir: &Path, cur: V) -> Option<Sprint> {
    let snap = read(dir, cur)?;
    let rows = rows_of(dir, cur, &Index::of(dir, Some(cur)));
    let t = tally(&snap, &rows);
    let open: HashSet<String> = rows
        .open
        .iter()
        .filter(|l| holds(&snap.keys, l))
        .map(|l| key(l))
        .collect();
    Some(Sprint {
        open: open.len(),
        committed: t.committed + t.interrupted,
    })
}

/// The last cut's score as `--stats --json` emits it.
#[derive(Debug, serde::Serialize)]
pub(crate) struct LastWindow {
    pub version: String,
    pub line: String,
}

/// The most recent cut's `## Window` line: the scored frozen note with the latest `cut` day, the
/// higher version on a tie. A note with no `## Window` line (a stray wave file, an unplanned tag
/// note) is not a scored cut, and the number alone is not the order: `--renumber` cuts a version
/// above the one it opens.
pub(crate) fn last(dir: &Path) -> Option<LastWindow> {
    let (_, v, line) = projects::version_notes(&dir.join("versions"))
        .into_iter()
        .filter_map(|(v, path)| {
            let line = frozen_line(&fs::read_to_string(path).ok()?)?;
            Some((cut_day(&line), v, line))
        })
        .max_by_key(|(day, v, _)| (*day, *v))?;
    Some(LastWindow {
        version: projects::fmt_version(v),
        line,
    })
}

/// The `cut` day a [`cut_line`] records, `None` when the line has none.
fn cut_day(line: &str) -> Option<NaiveDate> {
    let (_, rest) = line.split_once(", cut ")?;
    NaiveDate::parse_from_str(rest.get(..10)?, "%Y-%m-%d").ok()
}

/// The open version of a project whose window is frozen: a focus project whose open version
/// has its snapshot. Only then does a new row default to the next window. One read per filing,
/// so a caller routing many rows checks once.
fn frozen_window(dir: &Path, cur: Option<V>) -> Option<V> {
    cur.filter(|c| projects::prio_of(dir) == "focus" && read(dir, *c).is_some())
}

/// Where a new row goes.
#[derive(Debug, PartialEq)]
pub(crate) enum Route {
    /// The open version, as before: no frozen window, an epic, or a row aimed later.
    Open,
    /// The open version through the interrupt lane, tagged [`INTERRUPT`].
    Interrupt,
    /// The next window.
    Next(V),
}

/// Route a new row `line` into `window`, the [`frozen_window`] of its project. `source` is the
/// writer's own interrupt signal: a person at a terminal, or a human's want channel. A red or
/// anything urgent says so on the row (`#interrupt`, `#urgent`).
///
/// A row aimed later keeps its aim, and one aimed at the open version by hand is pushed into
/// the window, so it goes in as an interrupt the score counts.
fn route(window: Option<V>, line: &str, source: bool) -> Route {
    let Some(c) = window else {
        return Route::Open;
    };
    if sheet::is_later(line, window) || crate::epics::is_epic(line) {
        return Route::Open;
    }
    let urgent = md::task_priority(line) == Some("#urgent");
    if source || sheet::target(line) == Some(c) || has_interrupt(line) || urgent {
        Route::Interrupt
    } else {
        Route::Next(projects::next_version(Some(c), projects::Bump::Patch))
    }
}

/// Is `want` (`--want`'s channel) the human's own ask? `#requested` rides on every want, so
/// it cannot be the signal (`projects::MACHINE_WANTS`).
pub(crate) fn human_channel(want: &str) -> bool {
    !projects::MACHINE_WANTS.contains(&want)
}
/// `line` routed: tagged for the interrupt lane or aimed at the next window.
fn apply(line: &str, route: &Route) -> String {
    match route {
        Route::Open => line.to_string(),
        Route::Interrupt => md::add_tag(line, INTERRUPT),
        Route::Next(v) => crate::project_sweep::retag(line, *v, false).0,
    }
}

/// `block` as project `dir` (open version `cur`) takes it: in a frozen window each open row is
/// tagged for the interrupt lane when `interrupt`, else aimed at the next window.
pub(crate) fn admit(
    dir: &Path,
    cur: Option<V>,
    block: Vec<String>,
    interrupt: bool,
) -> Vec<String> {
    let window = frozen_window(dir, cur);
    block
        .into_iter()
        .map(|l| {
            if md::is_open_task(&l) {
                apply(&l, &route(window, &l, interrupt))
            } else {
                l
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(d: &str) -> NaiveDate {
        NaiveDate::parse_from_str(d, "%Y-%m-%d").unwrap()
    }

    fn project(tag: &str, prio: &str, human: &str, board: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-window-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("agent")).unwrap();
        fs::write(
            dir.join("README.md"),
            format!("# demo\nVersion: v0.2.0 #alpha {prio}\n\n## Tasks\n{human}"),
        )
        .unwrap();
        fs::write(
            dir.join("agent/README.md"),
            format!("# demo - agent board\n\n## Tasks\n{board}"),
        )
        .unwrap();
        dir
    }

    const HUMAN: &str = "- [ ] feat(ui): menu #urgent <!-- id:db-1 -->\n\
                         - [x] fix(ui): crash <!-- id:db-2 done:2026-11-18 -->\n\
                         - [ ] feat(ui): later #v0.3.0 <!-- id:db-3 -->\n\
                         - [ ] epic(ui): ui to standard <!-- id:db-4 -->\n";
    const BOARD: &str = "- [ ] fix(ci): flaky <!-- id:db-5 -->\n\
                         - [ ] chore(docs): no id row\n";

    /// The snapshot holds the open version's open rows of both lanes, nothing aimed later and
    /// no untagged epic, and a second record is refused.
    #[test]
    fn a_window_commits_its_open_rows_once() {
        let dir = project("record", "", HUMAN, BOARD);
        let ix = Index::of(&dir, Some((0, 2, 0)));
        let n = record(
            &dir,
            "demo",
            (0, 2, 0),
            day("2026-11-19"),
            Some(day("2026-11-26")),
            &ix,
        )
        .unwrap();
        assert_eq!(n, Some(3));
        let snap = read(&dir, (0, 2, 0)).unwrap();
        assert_eq!(
            (snap.opened, snap.due),
            (day("2026-11-19"), Some(day("2026-11-26")))
        );
        let mut keys: Vec<&String> = snap.keys.iter().collect();
        keys.sort();
        assert_eq!(keys, ["chore(docs): no id row", "db-1", "db-5"]);
        // NEGATIVE CONTROL: a second record keeps the first snapshot.
        fs::write(
            dir.join("agent/README.md"),
            format!("## Tasks\n{BOARD}- [ ] fix(x): new <!-- id:db-9 -->\n"),
        )
        .unwrap();
        assert_eq!(
            record(&dir, "demo", (0, 2, 0), day("2026-11-20"), None, &ix).unwrap(),
            None
        );
        assert_eq!(read(&dir, (0, 2, 0)).unwrap().keys.len(), 3);
        let _ = fs::remove_dir_all(&dir);
    }

    /// A window commits only what fits one cadence of shipped weight: with nothing shipped the
    /// budget is 0, so the pinned row plus the board floor's first rows, not every open row.
    #[test]
    fn a_window_commits_only_what_fits() {
        let board = "- [ ] fix(a): one <!-- id:db-11 -->\n\
                     - [ ] fix(a): two <!-- id:db-12 -->\n\
                     - [ ] fix(a): three <!-- id:db-13 -->\n\
                     - [ ] fix(a): four <!-- id:db-14 -->\n\
                     - [ ] fix(a): five <!-- id:db-15 -->\n\
                     - [ ] fix(a): six <!-- id:db-16 -->\n\
                     - [ ] fix(a): hot #urgent <!-- id:db-17 -->\n";
        let dir = project("fit", "", "", board);
        let ix = Index::of(&dir, Some((0, 2, 0)));
        let n = record(&dir, "demo", (0, 2, 0), day("2026-11-19"), None, &ix).unwrap();
        // NEGATIVE CONTROL: without the fit all 7 open rows were committed.
        assert_eq!(n, Some(4));
        let mut keys: Vec<String> = read(&dir, (0, 2, 0)).unwrap().keys.into_iter().collect();
        keys.sort();
        assert_eq!(keys, ["db-11", "db-12", "db-13", "db-17"]);
        let _ = fs::remove_dir_all(&dir);
    }

    /// The agent lane fills the window's span of its shipped weight, skipping a row too heavy
    /// for what is left; the human lane commits only its pinned rows; a row on both sheets takes
    /// one agent slot.
    #[test]
    fn a_window_spends_the_agent_capacity_and_takes_only_pinned_human_rows() {
        let today = chrono::Local::now().date_naive();
        let human = "- [ ] feat(a): on both sheets #size/l <!-- id:db-21 -->\n\
                     - [ ] feat(h): unpinned <!-- id:db-31 -->\n\
                     - [ ] feat(h): pinned #urgent <!-- id:db-32 -->\n";
        let board = format!(
            "- [ ] fix(a): one #size/l <!-- id:db-21 -->\n\
             - [ ] fix(a): two #size/l <!-- id:db-22 -->\n\
             - [ ] fix(a): three #size/m <!-- id:db-23 -->\n\
             - [ ] fix(a): too heavy #size/l <!-- id:db-24 -->\n\
             - [ ] fix(a): light #size/s <!-- id:db-25 -->\n\
             - [ ] fix(a): no room #size/m <!-- id:db-26 -->\n\
             ### Done\n\
             - [x] fix(z): shipped #size/xl <!-- id:db-29 pr:9 done:{today} -->\n"
        );
        let dir = project("capacity", "", human, &board);
        let due = today + chrono::Duration::days(7);
        // 21 shipped over the last week is 21 for a week: 8 + 8 + 3 + 1, past 24 and 26 that do not fit.
        assert_eq!(capacity(&dir, today, Some(due)), 21);
        let ix = Index::of(&dir, Some((0, 2, 0)));
        let n = record(&dir, "demo", (0, 2, 0), today, Some(due), &ix).unwrap();
        assert_eq!(n, Some(5));
        let mut keys: Vec<String> = read(&dir, (0, 2, 0)).unwrap().keys.into_iter().collect();
        keys.sort();
        assert_eq!(keys, ["db-21", "db-22", "db-23", "db-25", "db-32"]);
        // A one-day window holds a seventh of it, so the board floor decides.
        assert_eq!(capacity(&dir, today, Some(today)), 3);
        let _ = fs::remove_dir_all(&dir);
    }

    /// A Target day for the open version brings the due day forward; one for another version, or
    /// a later one, does not.
    #[test]
    fn a_target_for_the_open_version_brings_its_due_day_forward() {
        let cut = day("2026-11-18");
        assert_eq!(
            due_on(Some(cut), 7, (0, 5, 3), None),
            Some(day("2026-11-25"))
        );
        assert_eq!(
            due_on(
                Some(cut),
                7,
                (0, 5, 3),
                Some(((0, 5, 3), day("2026-11-19")))
            ),
            Some(day("2026-11-19"))
        );
        assert_eq!(
            due_on(
                Some(cut),
                7,
                (0, 5, 3),
                Some(((0, 5, 4), day("2026-11-19")))
            ),
            Some(day("2026-11-25"))
        );
        assert_eq!(
            due_on(
                Some(cut),
                7,
                (0, 5, 3),
                Some(((0, 5, 3), day("2026-12-01")))
            ),
            Some(day("2026-11-25"))
        );
        assert_eq!(
            due_on(None, 7, (0, 5, 3), Some(((0, 5, 3), day("2026-11-19")))),
            Some(day("2026-11-19"))
        );
    }

    /// A bullet added under the snapshot is not committed, a committed row deferred to a later
    /// version is carried, and an id-less row tagged `#interrupt` by hand keeps its identity.
    #[test]
    fn a_snapshot_reads_only_its_rows_and_follows_a_row_that_moved() {
        let dir = project("moved", "", HUMAN, BOARD);
        let ix = Index::of(&dir, Some((0, 2, 0)));
        record(&dir, "demo", (0, 2, 0), day("2026-11-19"), None, &ix).unwrap();
        let note = projects::agent_note_path(&dir, "v0.2.0");
        let body = fs::read_to_string(&note).unwrap();
        fs::write(&note, format!("{body}- a note someone added later\n")).unwrap();
        let snap = read(&dir, (0, 2, 0)).unwrap();
        assert_eq!(snap.keys.len(), 3, "{:?}", snap.keys);
        fs::write(
            dir.join("README.md"),
            "# demo\nVersion: v0.2.0\n\n## Tasks\n- [ ] feat(ui): menu #v0.3.0 <!-- id:db-1 -->\n",
        )
        .unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "## Tasks\n- [x] fix(ci): flaky <!-- id:db-5 done:2026-11-20 -->\n\
             - [ ] chore(docs): no id row #interrupt\n",
        )
        .unwrap();
        let t = tally(&snap, &rows_of(&dir, (0, 2, 0), &ix));
        assert_eq!(
            t,
            Tally {
                committed: 3,
                delivered: 1,
                open: 2,
                dropped: 0,
                interrupted: 0
            }
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// Delivered, carried, dropped and interrupted are counted against the snapshot, by id or
    /// by text for a row with none.
    #[test]
    fn a_tally_counts_against_the_snapshot() {
        let dir = project("tally", "", HUMAN, BOARD);
        let ix = Index::of(&dir, Some((0, 2, 0)));
        record(
            &dir,
            "demo",
            (0, 2, 0),
            day("2026-11-19"),
            Some(day("2026-11-26")),
            &ix,
        )
        .unwrap();
        // db-1 ships, db-5 is dropped, the no-id row stays open, two interrupts come in (one
        // closed), and an untagged add is not counted as anything.
        fs::write(
            dir.join("README.md"),
            "# demo\nVersion: v0.2.0\n\n## Tasks\n\
             - [x] feat(ui): menu <!-- id:db-1 done:2026-11-20 -->\n\
             - [x] fix(ui): hotfix #interrupt <!-- id:db-7 done:2026-11-21 -->\n",
        )
        .unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "## Tasks\n\
             - [x] fix(ci): flaky <!-- id:db-5 dropped: dup -->\n\
             - [ ] chore(docs): no id row #high\n\
             - [ ] fix(red): main red #interrupt <!-- id:db-8 -->\n\
             - [ ] feat(x): slipped in <!-- id:db-9 -->\n",
        )
        .unwrap();
        let snap = read(&dir, (0, 2, 0)).unwrap();
        let t = tally(&snap, &rows_of(&dir, (0, 2, 0), &ix));
        assert_eq!(
            t,
            Tally {
                committed: 3,
                delivered: 1,
                open: 1,
                dropped: 1,
                interrupted: 2
            }
        );
        let line = cut_line(
            &snap,
            &t,
            day("2026-11-28"),
            Some(((0, 2, 0), day("2026-11-27"))),
        );
        assert_eq!(
            line,
            "committed 3, delivered 1, carried 1, dropped 1, interrupted 2; opened 2026-11-19, \
             due 2026-11-26, cut 2026-11-28 (late by 2 days); target v0.2.0 2026-11-27 missed by 1 day"
        );
        let on_time = cut_line(&snap, &t, day("2026-11-26"), None);
        assert!(on_time.ends_with("cut 2026-11-26 (on time)"), "{on_time}");
        let _ = fs::remove_dir_all(&dir);
    }

    /// The Sprint count: closing a committed row lowers `open`, an interrupt raises both, and an
    /// add outside the window (or no window at all) changes nothing.
    #[test]
    fn the_sprint_falls_on_a_close_and_rises_only_on_an_interrupt() {
        let dir = project("sprint", "", HUMAN, BOARD);
        assert_eq!(sprint(&dir, (0, 2, 0)), None, "no window, no sprint");
        let ix = Index::of(&dir, Some((0, 2, 0)));
        record(&dir, "demo", (0, 2, 0), day("2026-11-19"), None, &ix).unwrap();
        let at = |board: &str| {
            fs::write(dir.join("agent/README.md"), format!("## Tasks\n{board}")).unwrap();
            let s = sprint(&dir, (0, 2, 0)).unwrap();
            (s.open, s.committed)
        };
        assert_eq!(at(BOARD), (3, 3));
        assert_eq!(
            at("- [x] fix(ci): flaky <!-- id:db-5 done:2026-11-20 -->\n\
                - [ ] chore(docs): no id row\n"),
            (2, 3),
            "a close lowers open"
        );
        // NEGATIVE CONTROL: a plain add is outside the window.
        assert_eq!(
            at(&format!(
                "{BOARD}- [ ] feat(x): slipped in <!-- id:db-9 -->\n"
            )),
            (3, 3)
        );
        assert_eq!(
            at(&format!(
                "{BOARD}- [ ] fix(red): main red #interrupt <!-- id:db-8 -->\n"
            )),
            (4, 4),
            "an interrupt enters the window"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// In a frozen focus window an add goes to the next window unless it is an interrupt; a
    /// project that is not focus, or has no snapshot, routes nothing.
    #[test]
    fn a_frozen_window_sends_adds_to_the_next_one() {
        let dir = project("route", "#prio/focus", HUMAN, BOARD);
        let cur = Some((0, 2, 0));
        let row = "- [ ] fix(ui): new bug #high #c1119 <!-- id:db-10 -->";
        // NEGATIVE CONTROL: no snapshot yet, so the window is open to every add.
        assert_eq!(route(frozen_window(&dir, cur), row, false), Route::Open);
        let ix = Index::of(&dir, cur);
        record(&dir, "demo", (0, 2, 0), day("2026-11-19"), None, &ix).unwrap();
        let next = route(frozen_window(&dir, cur), row, false);
        assert_eq!(next, Route::Next((0, 2, 1)));
        assert!(
            apply(row, &next).contains("#v0.2.1"),
            "{}",
            apply(row, &next)
        );
        assert_eq!(route(frozen_window(&dir, cur), row, true), Route::Interrupt);
        assert_eq!(
            apply(row, &Route::Interrupt),
            "- [ ] fix(ui): new bug #high #c1119 #interrupt <!-- id:db-10 -->"
        );
        let urgent = "- [ ] fix(ui): main red #urgent";
        assert_eq!(
            route(frozen_window(&dir, cur), urgent, false),
            Route::Interrupt
        );
        let tagged = "- [ ] fix(ui): red #interrupt";
        assert_eq!(
            route(frozen_window(&dir, cur), tagged, false),
            Route::Interrupt
        );
        // A row aimed later and an epic keep their place; one aimed at the open version by
        // hand goes in as an interrupt.
        assert_eq!(
            route(frozen_window(&dir, cur), "- [ ] feat(ui): x #v0.4.0", false),
            Route::Open
        );
        assert_eq!(
            route(frozen_window(&dir, cur), "- [ ] feat(ui): x #v0.2.0", false),
            Route::Interrupt
        );
        assert_eq!(
            route(frozen_window(&dir, cur), "- [ ] epic(ui): big", false),
            Route::Open
        );
        // NEGATIVE CONTROL: the same snapshot on a project that is not focus routes nothing.
        let readme = fs::read_to_string(dir.join("README.md")).unwrap();
        fs::write(dir.join("README.md"), readme.replace(" #prio/focus", "")).unwrap();
        assert_eq!(route(frozen_window(&dir, cur), row, false), Route::Open);
        let _ = fs::remove_dir_all(&dir);
    }
}
