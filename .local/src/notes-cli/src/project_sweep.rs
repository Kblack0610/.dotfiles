//! Sweep a project sheet's `## Tasks` section into the sections the sheet is read by:
//! `### Epics` (the human sheet's epic rows), `### Now` (rows started, `[/]`), `### Next up`
//! (the top of the rank), `### Backlog` (the rest; on the agent board `### Board`, every open
//! row, since all of it is planned work), then `---` and `### Done` (the
//! rows closed in the last few days). Sections are a pure function of the rows and the day: nothing is
//! placed by hand, and priority stays a tag, sorted within each section ([`crate::rank`]).
//!
//! The release tag is the source of truth, exactly as the priority tag is, and no heading
//! repeats it. Two rules the lane sweep has no equivalent for, applied only by a pass that
//! rewrites rows ([`Ctx::rewrite`]); the sweep at the end of every write only moves them. A row can never be aimed at a
//! release already closed, so a tag below the sheet's `Version:` goes and the row follows the
//! open version. And `#urgent` is legal only in the open version, so a row aimed later is
//! rewritten to `#high`. An epic row carries no priority tag at all: it ranks as its most
//! urgent open row, so the rewriting pass drops one.

use std::collections::HashSet;

use chrono::{NaiveDate, NaiveDateTime, NaiveTime};

use crate::config::SheetShape;
use crate::epics;
use crate::md;
use crate::projects;
use crate::rank;
use crate::sheet::{self, V};
use crate::sweep::{self, Block};

/// What a sweep lays a sheet out against: the day, the section sizes, the project's open
/// version (the human sheet's `Version:`, which an agent board has no line of its own for) and
/// its systems.
#[derive(Clone)]
pub(crate) struct Ctx {
    pub today: NaiveDate,
    pub shape: SheetShape,
    pub open: Option<V>,
    /// Rewrite rows as well as move them: drop a closed release's tag, demote `#urgent` aimed
    /// later, tag the untagged, put tags in order. Off for the sweep every write ends with,
    /// because a caller holding a row's bytes (`--exact`) must still find it after another
    /// write; the explicit sweep, the nightly and the editor save turn it on.
    pub rewrite: bool,
    /// The project's systems in their list's order (`project-stage-check --list`), which
    /// `### Epics` follows ([`epic_order`]); empty when the project has none.
    pub systems: Vec<crate::standing::System>,
    /// The agent board, which lays every open row no item is behind under `### Board` and strips
    /// the retired [`BACKLOG`] token. `false` on the human sheet.
    pub tiered: bool,
    /// The project's targeted version and the rows aimed at it ([`rank::Aim`]): such a row sorts
    /// as if due on the target day. It only orders; [`pinned`] reads the row's own rank.
    pub aim: Option<rank::Aim>,
}

/// The retired marker token of the agent board's old Backlog tier. No row takes it: the agent
/// board is all planned work, and a nice-to-have goes to the project's `improvements.md`, never
/// onto a board (the human, 2026-11-23). Every agent-board sweep strips it ([`sections`]).
pub(crate) const BACKLOG: &str = "tier:backlog";

/// Is `line` in the Backlog tier.
pub(crate) fn in_backlog(line: &str) -> bool {
    md::marker_of(line).is_some_and(|m| m.split_whitespace().any(|t| t == BACKLOG))
}

/// `line` with its [`BACKLOG`] token on or off, its bytes kept when it already says so.
pub(crate) fn with_backlog(line: &str, on: bool) -> String {
    match (in_backlog(line), on) {
        (false, true) => md::add_marker(line, BACKLOG),
        (true, false) => md::remove_marker_token(line, BACKLOG),
        _ => line.to_string(),
    }
}

/// Is the row a plan-chain phase whose gate is open: it carries a `#after/<id>` (read before its
/// marker comment) and no such `<id>` is in `waiting`, this sheet's open rows not yet started.
/// A phase behind an unstarted one cannot run today, so it takes a slot like any row; starting
/// the predecessor writes the sheet, and that write's sweep pins the phase.
fn gate_open(line: &str, waiting: &HashSet<String>) -> bool {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    let mut gates = head
        .split_whitespace()
        .filter_map(|w| w.strip_prefix("#after/"))
        .peekable();
    gates.peek().is_some() && gates.all(|id| !waiting.contains(id))
}

/// Does the row's `#at/` gate open within the rank's soon window: `#at/<HHMM>` opens today,
/// `#at/<YYYY-MM-DD>/<HHMM>` on its date (the board forms agent-queue's gate reads). Dispatch
/// skips backlog rows, so a dated row pushed there would never start on its date. A row that also
/// carries `#after/` is left to [`gate_open`]: it cannot start before its predecessor does.
fn at_soon(line: &str, today: NaiveDate) -> bool {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    !head.contains("#after/")
        && at_gates(head).any(|at| match at.split_once('/') {
            None => hhmm(at).is_some(),
            Some((day, time)) => {
                hhmm(time).is_some()
                    && NaiveDate::parse_from_str(day, "%Y-%m-%d")
                        .is_ok_and(|d| (d - today).num_days() <= rank::DUE_SOON_DAYS)
            }
        })
}

/// `HHMM` as a clock time, `None` unless it is four digits, hours under 24 and minutes under 60.
fn hhmm(t: &str) -> Option<NaiveTime> {
    if t.len() != 4 || !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    NaiveTime::from_hms_opt(t[..2].parse().ok()?, t[2..].parse().ok()?, 0)
}

/// The `#at/` gates in a row's text before its `<!--` marker, each as written.
fn at_gates(line: &str) -> impl Iterator<Item = &str> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    head.split_whitespace()
        .filter_map(|w| w.strip_prefix("#at/"))
}

/// The dated gate of a row, `#at/<YYYY-MM-DD>/<HHMM>`: when dispatch starts it. A plain
/// `#at/<HHMM>` has no date and is `None`.
pub(crate) fn at_dated(line: &str) -> Option<NaiveDateTime> {
    at_gates(line).find_map(|at| {
        let (day, time) = at.split_once('/')?;
        Some(
            NaiveDate::parse_from_str(day, "%Y-%m-%d")
                .ok()?
                .and_time(hhmm(time)?),
        )
    })
}

/// A row the agent board never leaves to its backlog and a release window always commits:
/// started or queued (`[/]`), an epic, a parent another open row names with `#of/<id>`, a
/// plan-chain phase whose `#after/<id>` gate is open (a chain's next phase waits for no other
/// row), a row whose `#at/` gate opens within the soon window, or one the rank puts first
/// (`#urgent`, due within the rank's soon window).
fn pinned(
    line: &str,
    parents: &HashSet<String>,
    waiting: &HashSet<String>,
    today: NaiveDate,
) -> bool {
    let r = rank::of(line, today);
    md::is_in_progress(line)
        || epics::is_epic(line)
        || md::task_priority(line) == Some("#urgent")
        || r.due < rank::DUE_LATER
        || gate_open(line, waiting)
        || at_soon(line, today)
        || md::row_id(line).is_some_and(|id| parents.contains(&id))
}

/// Which of `rows` are [`pinned`]: the rows the board keeps whatever its tier, so work already
/// started, queued or gated open is never sent where dispatch does not look.
fn pins(rows: &[&str], today: NaiveDate) -> Vec<bool> {
    let parents: HashSet<String> = rows.iter().filter_map(|l| epics::parent_of(l)).collect();
    let waiting = waiting(rows);
    rows.iter()
        .map(|l| pinned(l, &parents, &waiting, today))
        .collect()
}

/// The ids of `rows` not yet started: what an `#after/<id>` gate on the same sheet waits on.
fn waiting(rows: &[&str]) -> HashSet<String> {
    rows.iter()
        .filter(|l| !md::is_in_progress(l))
        .filter_map(|l| md::row_id(l))
        .collect()
}

/// Which of `rows`, in sheet order, a release window commits at `budget` (a weight,
/// `window::record`): the [`pinned`] rows whatever they weigh, then the `#requested` rows and
/// then the others, each in sheet order while its weight fits what is left, and at least `floor`
/// of those whatever they weigh. A row aimed later than `open` takes no slot.
pub(crate) fn fit(
    rows: &[&str],
    budget: u32,
    floor: usize,
    today: NaiveDate,
    open: Option<V>,
) -> Vec<bool> {
    let asked = |i: usize| rank::of(rows[i], today).req == 0;
    let pins = pins(rows, today);
    let weight = |i: usize| projects::size_weight(rows[i]);
    let pinned_weight: u32 = (0..rows.len()).filter(|&i| pins[i]).map(weight).sum();
    let mut room = budget.saturating_sub(pinned_weight);
    let free = |i: usize| !pins[i] && !sheet::is_later(rows[i], open);
    let mut stays = pins.clone();
    let mut kept = 0;
    let order = (0..rows.len())
        .filter(|&i| free(i) && asked(i))
        .chain((0..rows.len()).filter(|&i| free(i) && !asked(i)))
        .collect::<Vec<_>>();
    for i in order {
        let fits = weight(i) <= room;
        if fits {
            room -= weight(i);
        }
        if fits || kept < floor {
            stays[i] = true;
            kept += 1;
        }
    }
    stays
}

/// Where an epic row sits in `### Epics`: a `#new` one first, so what the triager filed
/// is seen first, then by its system in the list's order, an area the list does not name after
/// those by its word; rank decides within one system, the sort being stable.
fn epic_order(line: &str, systems: &[crate::standing::System]) -> (bool, usize, String) {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    let new = head.split_whitespace().any(|w| w == "#new");
    let area = projects::row_type_area(line)
        .map(|(_, a)| a.to_lowercase())
        .unwrap_or_default();
    let at = crate::standing::system_of(systems, &area)
        .and_then(|id| systems.iter().position(|s| s.id == id))
        .unwrap_or(systems.len());
    (
        !new,
        at,
        if at < systems.len() {
            String::new()
        } else {
            area
        },
    )
}

/// One rung of the release ladder from `at`, in `dir` (`-1` sooner, `+1` later). `ladder` is
/// the releases open rows are aimed at.
///
/// A ladder, not a ring. `PRIORITY_RING` wraps through the no-tag slot because every priority
/// is legal; release steps are bounded on one side and open on the other. Going sooner CLAMPS
/// at `cur`, because a closed release cannot take work. Going later MINTS the next patch past
/// the end, because the roadmap is supposed to grow: that is how a pile becomes small releases.
///
/// `None` when the row is already in the open version and the step is sooner: only that
/// direction can fail.
pub(crate) fn step_version(cur: V, ladder: &[V], at: V, dir: i32) -> Option<V> {
    if dir < 0 {
        if at <= cur {
            return None;
        }
        return Some(
            ladder
                .iter()
                .copied()
                .filter(|v| *v < at)
                .max()
                .unwrap_or(cur),
        );
    }
    Some(
        ladder
            .iter()
            .copied()
            .filter(|v| *v > at)
            .min()
            .unwrap_or_else(|| {
                // Past the last planned release: open the next patch above the highest on the sheet,
                // so `demote` on the last one still has somewhere to put the task.
                let top = ladder.iter().copied().max().unwrap_or(cur).max(at);
                (top.0, top.1, top.2 + 1)
            }),
    )
}

/// `line` with its priority legal for a row aimed later than the open version, and the report
/// when that rewrote it.
fn cap_priority(line: String) -> (String, Option<String>) {
    if md::task_priority(&line) != Some("#urgent") {
        return (line, None);
    }
    let note = format!(
        "{}: #urgent -> #high (urgent is only legal in the open version)",
        md::task_text(&line)
    );
    // Strip the priority by re-adding the one we want: `add_tag` no-ops on a duplicate, so
    // drop `#urgent` first and let the lane tag land in the same place.
    (
        md::add_tag(&md::strip_priority_tag(&line), "#high"),
        Some(note),
    )
}

/// Retag `line` for release `to`, returning the new line and a report when something was
/// rewritten beyond the tag itself.
pub(crate) fn retag(line: &str, to: V, to_is_current: bool) -> (String, Option<String>) {
    let (stripped, _) = md::split_version(line);
    let (stripped, note) = if to_is_current {
        (stripped, None)
    } else {
        cap_priority(stripped)
    };
    (
        md::add_tag(&stripped, &format!("#{}", projects::fmt_version(to))),
        note,
    )
}

/// Pure core: reorganize a sheet's `## Tasks` section. Returns the new content and a report of
/// everything it rewrote, or `None` when the sheet is already in this shape or has no section.
///
/// Tags are checked against the sheet's own `Version:` line. An agent board has none, so its
/// rows keep their tags as they are; its sections still use `ctx.open`.
pub(crate) fn sweep_sheet(content: &str, ctx: &Ctx) -> Option<(String, Vec<String>)> {
    let lines: Vec<&str> = content.lines().collect();
    let span = md::section_span(&lines, sheet::TASKS)?;
    let cur = projects::sheet_version(content);

    let mut report: Vec<String> = Vec::new();
    let mut body: Vec<String> = Vec::new();
    for l in &lines[span.clone()] {
        // The generated `- [ ] ` placeholder is scaffold, not content: the rebuild re-emits it.
        // A blank goes to `task_body`, which keeps one inside a row's brief and drops the rest.
        if l.trim().is_empty() {
            body.push(String::new());
            continue;
        }
        if md::is_empty_unchecked(l) {
            continue;
        }
        if !md::is_open_task(l) || !ctx.rewrite {
            body.push((*l).to_string());
            continue;
        }
        // An epic ranks as its most urgent open row (`epics::Index::epic_priority`), so a tag of
        // its own is read by nothing and goes.
        let mut l = (*l).to_string();
        if let Some(tag) = md::task_priority(&l).filter(|_| epics::is_epic(&l)) {
            report.push(format!(
                "{}: {tag} dropped, an epic ranks as its most urgent open row",
                md::task_text(&l)
            ));
            l = md::strip_priority_tag(&l);
        }
        let l = l.as_str();
        let stale = matches!((sheet::target(l), cur), (Some(t), Some(c)) if t < c);
        if stale {
            report.push(format!(
                "{}: tag dropped, {} closed",
                md::task_text(l),
                md::version_tag(l).unwrap_or_default()
            ));
            body.push(md::split_version(l).0);
        } else if sheet::is_later(l, cur) {
            let (line, note) = cap_priority(l.to_string());
            report.extend(note);
            body.push(line);
        } else {
            body.push(l.to_string());
        }
    }

    let refs: Vec<&str> = body.iter().map(String::as_str).collect();
    let mut out: Vec<String> = lines[..span.start]
        .iter()
        .map(|l| (*l).to_string())
        .collect();
    // Canonical tag order, applied once at the end: the retag above and the default-priority
    // tag inside `task_body` add tags at different points, so this is what stops the same
    // task being spelled two ways depending on how it got here.
    out.extend(sections(&refs, ctx).into_iter().map(|l| {
        if ctx.rewrite {
            md::normalize_tags(&l)
        } else {
            l
        }
    }));
    out.push(String::new());
    out.extend(lines[span.end..].iter().map(|l| (*l).to_string()));

    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    // Trailing blank lines accumulate otherwise: the section's own blank separator plus
    // whatever followed it.
    while joined.contains("\n\n\n") {
        joined = joined.replace("\n\n\n", "\n\n");
    }
    (joined != content).then_some((joined, report))
}

/// The section an open row is laid out in, in sheet order. The sections follow the queue
/// (human, 2026-11-09): Now is the rows whose item runs (`run:`), Next up every queued row,
/// uncapped, and the rows no item is behind after them: on the agent board all in Board, which
/// is all the work planned (human, 2026-11-23), on the human sheet all in Backlog. An epic row is in Epics
/// whatever its box.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Section {
    Epics,
    Now,
    Next,
    Board,
    Backlog,
}

impl Section {
    /// The word `notes board --json` prints in a row's `section`.
    pub(crate) fn name(self) -> &'static str {
        match self {
            Section::Epics => "epics",
            Section::Now => "now",
            Section::Next => "next",
            Section::Board => "board",
            Section::Backlog => "backlog",
        }
    }
}

/// [`Section`] of the open row `line` on a tiered sheet (`tiered`: the agent board) or not
/// (the human sheet): the one rule the sweep lays a sheet out by and the
/// feed reports, so a view grouping by it draws the sheet's order.
pub(crate) fn section_of(line: &str, tiered: bool) -> Section {
    if epics::is_epic(line) {
        Section::Epics
    } else if crate::project_tasks::is_running(line) {
        Section::Now
    } else if line.trim_start().starts_with("- [/]") {
        Section::Next
    } else if tiered {
        Section::Board
    } else {
        Section::Backlog
    }
}

/// Lay one `## Tasks` body out in its sections. A heading is emitted only over rows, except
/// `### Done`, which is always there; the empty `- [ ] ` slot closes the open sections.
fn sections(body: &[&str], ctx: &Ctx) -> Vec<String> {
    let tb = sweep::task_body(body, ctx.rewrite);
    let (mut open, mut done) = (tb.open, tb.done);
    // The retired Backlog tier: an agent-board row carries no token.
    if ctx.tiered {
        for b in open.iter_mut().chain(done.iter_mut()) {
            b[0] = with_backlog(&b[0], false);
        }
    }
    // Rows aimed past the open version sort last whatever their rank.
    open.sort_by_key(|b| {
        (
            sheet::is_later(&b[0], ctx.open),
            rank::aimed(&b[0], ctx.today, ctx.aim.as_ref()),
        )
    });
    // One slot a [`Section`], in its order, which is `TASK_SECTIONS`'s.
    let mut by: [Vec<Block>; sweep::TASK_SECTIONS.len()] = Default::default();
    for b in open {
        by[section_of(&b[0], ctx.tiered) as usize].push(b);
    }
    by[Section::Epics as usize].sort_by_cached_key(|b| epic_order(&b[0], &ctx.systems));
    // Newest close first, undated last; equal days keep file order.
    done.sort_by_key(|b| std::cmp::Reverse(crate::project_tasks::done_on(&b[0])));

    let mut out: Vec<String> = tb.prose;
    for (heading, rows) in sweep::TASK_SECTIONS.iter().zip(&by) {
        if rows.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push(heading.to_string());
        out.extend(rows.iter().flatten().cloned());
    }
    out.push(tb.placeholder.unwrap_or_else(|| "- [ ] ".to_string()));
    out.push(String::new());
    out.push("---".to_string());
    out.push("### Done".to_string());
    out.extend(done.into_iter().flatten());
    out
}

/// The closed rows of `## Tasks` that leave the sheet for the version note: every top-level
/// closed row not aimed at a later release that is undated (closed before `done:` was stamped,
/// or dropped), older than `done_days`, or past the `done_max` newest. As line ranges with the
/// indented lines under each row.
pub(crate) fn old_done(content: &str, ctx: &Ctx) -> Vec<std::ops::Range<usize>> {
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, sheet::TASKS) else {
        return Vec::new();
    };
    let rows: Vec<std::ops::Range<usize>> = crate::project_tasks::done_rows(content)
        .into_iter()
        .filter(|r| span.contains(&r.start) && !sheet::is_later(lines[r.start], ctx.open))
        .collect();
    let firsts: Vec<&str> = rows.iter().map(|r| lines[r.start]).collect();
    let keep = kept_done(&firsts, ctx.today, &ctx.shape);
    rows.into_iter()
        .enumerate()
        .filter(|(i, _)| !keep.contains(i))
        .map(|(_, r)| r)
        .collect()
}

/// Which of `rows` (each a closed row's first line) the Done window keeps: dated, not dropped,
/// closed under `done_days` ago, and among the `done_max` newest (ties keep file order). The one
/// window rule, for the sheets and `playtest.md` alike.
pub(crate) fn kept_done(
    rows: &[&str],
    today: NaiveDate,
    shape: &SheetShape,
) -> std::collections::HashSet<usize> {
    let mut kept: Vec<(NaiveDate, usize)> = rows
        .iter()
        .enumerate()
        .filter_map(|(i, l)| {
            crate::project_tasks::done_on(l)
                .filter(|_| !md::is_dropped(l))
                .filter(|d| (today - *d).num_days() < shape.done_days)
                .map(|d| (d, i))
        })
        .collect();
    kept.sort_by_key(|(d, i)| (std::cmp::Reverse(*d), *i));
    kept.into_iter()
        .take(shape.done_max)
        .map(|(_, i)| i)
        .collect()
}

/// `content` with `done:<today>` on each top-level closed row of `## Tasks` that has no
/// `done:`, was not dropped, and is not in `saved` as it stands: a box ticked by hand in the
/// editor, which no CLI verb dated. A close already undated in the saved file is an old one,
/// not this edit's, and keeps its bytes (the sweep rolls it off as undated).
pub(crate) fn stamp_undated(content: &str, saved: &str, today: NaiveDate) -> String {
    let lines: Vec<&str> = content.lines().collect();
    match md::section_span(&lines, sheet::TASKS) {
        Some(span) => stamp_undated_in(content, saved, today, span),
        None => content.to_string(),
    }
}

/// [`stamp_undated`] over the lines in `span` (0-based), for a file whose rows are not under
/// `## Tasks` (`playtest.md`).
pub(crate) fn stamp_undated_in(
    content: &str,
    saved: &str,
    today: NaiveDate,
    span: std::ops::Range<usize>,
) -> String {
    let before: std::collections::HashSet<&str> = saved.lines().map(str::trim_end).collect();
    let lines: Vec<&str> = content.lines().collect();
    let token = crate::project_tasks::done_token(today);
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    for r in crate::project_tasks::done_rows(content) {
        let l = lines[r.start];
        if span.contains(&r.start)
            && crate::project_tasks::done_on(l).is_none()
            && !md::is_dropped(l)
            && !before.contains(l.trim_end())
        {
            out[r.start] = md::add_marker(l, &token);
        }
    }
    let mut joined = out.join("\n");
    if content.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "\
# demo
Version: v0.12.1

## Tasks
- [ ] live one #high
- [ ] next one #v0.12.2
- [x] done one <!-- pr:307 done:2026-11-08 -->
";

    const TODAY: &str = "2026-11-09";

    fn ctx_with(done_days: i64, done_max: usize) -> Ctx {
        Ctx {
            today: NaiveDate::parse_from_str(TODAY, "%Y-%m-%d").unwrap(),
            shape: SheetShape {
                done_days,
                done_max,
                ..Default::default()
            },
            open: Some((0, 12, 1)),
            rewrite: true,
            systems: vec![],
            tiered: false,
            aim: None,
        }
    }

    fn ctx() -> Ctx {
        ctx_with(7, 30)
    }

    fn sweep(c: &str) -> String {
        sweep_sheet(c, &ctx()).expect("sheet reorganizes").0
    }

    fn ids(c: &str) -> Vec<String> {
        let mut v: Vec<String> = c
            .split("id:")
            .skip(1)
            .map(|r| r.split([' ', '-']).take(2).collect::<Vec<_>>().join("-"))
            .collect();
        v.sort();
        v
    }

    fn pos(out: &str, needle: &str) -> usize {
        out.find(needle)
            .unwrap_or_else(|| panic!("no {needle}:\n{out}"))
    }

    const CUR: V = (0, 12, 1);
    const LADDER: [V; 3] = [(0, 12, 1), (0, 12, 2), (0, 12, 4)];

    #[test]
    fn stepping_later_walks_the_ladder_it_finds_not_the_next_number() {
        // v0.12.3 does not exist on the sheet, so v0.12.2 steps to v0.12.4.
        assert_eq!(step_version(CUR, &LADDER, (0, 12, 2), 1), Some((0, 12, 4)));
        assert_eq!(step_version(CUR, &LADDER, CUR, 1), Some((0, 12, 2)));
    }

    #[test]
    fn stepping_later_past_the_last_release_opens_the_next_patch() {
        assert_eq!(step_version(CUR, &LADDER, (0, 12, 4), 1), Some((0, 12, 5)));
        // and from the open version alone, so a sheet with no roadmap can still grow one
        assert_eq!(step_version(CUR, &[CUR], CUR, 1), Some((0, 12, 2)));
    }

    #[test]
    fn stepping_sooner_walks_back_down_the_ladder() {
        assert_eq!(step_version(CUR, &LADDER, (0, 12, 4), -1), Some((0, 12, 2)));
        assert_eq!(step_version(CUR, &LADDER, (0, 12, 2), -1), Some(CUR));
    }

    // The clamp: a closed release cannot take work, so the ladder is bounded on this side.
    #[test]
    fn stepping_sooner_clamps_at_the_open_version() {
        assert_eq!(step_version(CUR, &LADDER, CUR, -1), None);
    }

    #[test]
    fn untagged_rows_stay_untagged_and_a_later_tag_stays_put() {
        let out = sweep(SHEET);
        assert!(out.contains("- [ ] live one #high\n"), "{out}");
        assert!(out.contains("- [ ] next one #v0.12.2\n"), "{out}");
        assert!(out.contains("- [x] done one <!-- pr:307"), "{out}");
    }

    // The whole layout, byte for byte: Epics, Now, Next up, Backlog, the slot, the rule, Done.
    #[test]
    fn the_sheet_is_laid_out_in_its_sections() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] low one #low\n- [x] old close <!-- done:2026-11-05 -->\n\
- [/] queued #low\n- [/] running #high <!-- run:1109 -->\n- [ ] epic(look): the look #high\n\
- [ ] fire #urgent\n- [ ] later one #v0.12.2\n- [x] new close <!-- done:2026-11-08 -->\n";
        let out = sweep_sheet(s, &ctx()).unwrap().0;
        assert_eq!(
            out,
            "# d\nVersion: v0.12.1\n\n## Tasks\n\
### Epics\n- [ ] epic(look): the look\n\n\
### Now\n- [/] running #high <!-- run:1109 -->\n\n\
### Next up\n- [/] queued #low\n\n\
### Backlog\n- [ ] fire #urgent\n- [ ] low one #low\n- [ ] later one #v0.12.2\n\
- [ ] \n\n---\n### Done\n\
- [x] new close <!-- done:2026-11-08 -->\n- [x] old close <!-- done:2026-11-05 -->\n"
        );
    }

    // An epic ranks as its most urgent open row, so the rewriting sweep drops its own priority
    // tag and says so; the sweep every write ends with moves rows only and keeps it.
    #[test]
    fn the_rewriting_sweep_drops_an_epics_priority_tag() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] epic(ui): menus #low <!-- id:dm-1 -->\n- [ ] fix(ui): a fault #high #of/dm-1 <!-- id:dm-2 -->\n";
        let (out, report) = sweep_sheet(s, &ctx()).unwrap();
        assert!(
            out.contains("- [ ] epic(ui): menus <!-- id:dm-1 -->\n"),
            "{out}"
        );
        assert!(
            out.contains("- [ ] fix(ui): a fault #high #of/dm-1"),
            "{out}"
        );
        assert_eq!(
            report,
            ["epic(ui): menus: #low dropped, an epic ranks as its most urgent open row"]
        );
        // NEGATIVE CONTROL: with rewrite off, nothing is rewritten.
        let moved = Ctx {
            rewrite: false,
            ..ctx()
        };
        let kept = sweep_sheet(s, &moved).map_or_else(|| s.to_string(), |r| r.0);
        assert!(kept.contains("epic(ui): menus #low"), "{kept}");
    }

    // Epics: a `#new` epic first, then by system in the list's order (an alias counts as its
    // system), an area the list does not name after those, rank within each; no list orders
    // by area word alone.
    #[test]
    fn epics_follow_the_system_list_with_new_ones_first() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] epic(zeta): off the list #c1101\n\
- [ ] epic(ui): menus #c1105\n\
- [ ] epic(ci): ci to standard #c1105\n\
- [ ] epic(hud): health bar #c1101\n\
- [ ] epic(net): rollback #new\n";
        let sys = |id: &str, aliases: &[&str]| crate::standing::System {
            id: id.into(),
            aliases: aliases.iter().map(|a| a.to_string()).collect(),
        };
        let listed = Ctx {
            systems: vec![sys("ui", &["hud"]), sys("ci", &[]), sys("net", &[])],
            ..ctx()
        };
        let epics = |c: &str| -> Vec<String> {
            c.lines()
                .filter(|l| l.starts_with("- [ ] epic("))
                .map(|l| l.split(')').next().unwrap()[11..].to_string())
                .collect()
        };
        let out = sweep_sheet(s, &listed).unwrap().0;
        assert_eq!(epics(&out), ["net", "hud", "ui", "ci", "zeta"], "{out}");
        let out = sweep_sheet(s, &ctx()).unwrap().0;
        assert_eq!(
            epics(&out),
            ["net", "ci", "hud", "ui", "zeta"],
            "by word:\n{out}"
        );
        assert_eq!(
            sweep_sheet(&sweep_sheet(s, &listed).unwrap().0, &listed),
            None,
            "settled"
        );
    }

    // Rank: due beats priority, priority beats age, within each section. Next up is every
    // queued row, however many: there is no cap.
    #[test]
    fn each_section_is_sorted_by_rank_and_next_up_is_the_whole_queue() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] old high #high #c1001\n- [ ] new high #high #c1101\n\
- [ ] due low #low #due1110\n- [ ] plain urgent #urgent\n\
- [/] q low #low\n- [/] q urgent #urgent\n- [/] q high #high\n";
        let out = sweep(s);
        let (next, backlog) = (pos(&out, "### Next up"), pos(&out, "### Backlog"));
        let queued = ["q urgent", "q high", "q low"];
        let rest = ["due low", "plain urgent", "old high", "new high"];
        for order in [&queued[..], &rest[..]] {
            let at: Vec<usize> = order.iter().map(|n| pos(&out, n)).collect();
            assert!(at.windows(2).all(|w| w[0] < w[1]), "ranked:\n{out}");
        }
        assert!(
            next < pos(&out, "q urgent") && pos(&out, "q low") < backlog,
            "{out}"
        );
        assert!(backlog < pos(&out, "due low"), "{out}");
        assert!(!out.contains("### Now"), "nothing runs:\n{out}");
    }

    // A row aimed past the open version is never next, however urgent its tags.
    #[test]
    fn a_row_aimed_later_never_enters_next_up() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] later #high #due1101 #v0.12.2\n";
        let out = sweep(s);
        assert!(!out.contains("### Next up"), "{out}");
        assert!(pos(&out, "### Backlog") < pos(&out, "later"), "{out}");
    }

    // The negative control: a hand-written section heading and a row out of rank order are
    // both corrected, and the result settles in one pass.
    #[test]
    fn a_hand_placed_row_is_moved_to_its_rank() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
### Now\n- [/] queued only #low\n\n### Next up\n- [ ] lowly #low\n\n### Backlog\n- [ ] fire #urgent\n\
- [ ] \n\n---\n### Done\n";
        let out = sweep(s);
        assert_eq!(out.matches("### Backlog").count(), 1, "{out}");
        assert!(!out.contains("### Now"), "a queued row is not Now:\n{out}");
        assert!(pos(&out, "### Next up") < pos(&out, "queued only"), "{out}");
        assert!(pos(&out, "fire") < pos(&out, "lowly"), "{out}");
        assert!(sweep_sheet(&out, &ctx()).is_none(), "settles:\n{out}");
    }

    // A row's detail lines travel with it, and no row is lost or doubled.
    #[test]
    fn rows_and_their_children_move_together_and_none_is_lost() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] b #low <!-- id:x-2 -->\n  detail of b\n- [ ] a #urgent <!-- id:x-1 -->\n\
\x20   - [ ] child of a\n- [x] c <!-- id:x-3 done:2026-11-09 -->\n  note on c\n";
        let out = sweep(s);
        assert_eq!(ids(&out), ids(s));
        assert!(out.contains("<!-- id:x-2 -->\n  detail of b\n"), "{out}");
        assert!(
            out.contains("<!-- id:x-1 -->\n    - [ ] child of a\n"),
            "{out}"
        );
        assert!(out.contains("done:2026-11-09 -->\n  note on c\n"), "{out}");
    }

    // A paragraph break inside a brief is part of the row's block: the sweep keeps it, moves the
    // block as one, and drops the blank that merely separates rows.
    #[test]
    fn a_blank_line_inside_a_rows_brief_survives_the_sweep() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] b #low <!-- id:x-2 -->\n  one\n\n  two\n    - nested\n\n- [ ] a #urgent <!-- id:x-1 -->\n\
\x20 note\n\n- [x] c <!-- id:x-3 done:2026-11-09 -->\n  done one\n\n  done two\n";
        let out = sweep(s);
        assert!(
            out.contains("<!-- id:x-2 -->\n  one\n\n  two\n    - nested\n"),
            "{out}"
        );
        assert!(out.contains("  done one\n\n  done two\n"), "{out}");
        assert!(pos(&out, "id:x-1") < pos(&out, "id:x-2"), "{out}");
        assert!(sweep_sheet(&out, &ctx()).is_none(), "settles:\n{out}");
    }

    // A tag on a closed release goes: the row follows the open version.
    #[test]
    fn a_tag_naming_a_closed_version_is_dropped() {
        let stale = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] stale #v0.11.0\n";
        let (out, report) = sweep_sheet(stale, &ctx()).unwrap();
        assert!(
            out.contains("- [ ] stale\n"),
            "untagged stays untagged:\n{out}"
        );
        assert!(
            report.iter().any(|r| r.contains("#v0.11.0 closed")),
            "{report:?}"
        );
    }

    #[test]
    fn urgent_is_demoted_on_a_row_aimed_later() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] fire #urgent #v0.12.2\n";
        let (out, report) = sweep_sheet(s, &ctx()).unwrap();
        assert!(out.contains("#high"), "demoted:\n{out}");
        assert!(!out.contains("#urgent"), "and not left urgent:\n{out}");
        assert!(
            report.iter().any(|r| r.contains("#urgent -> #high")),
            "{report:?}"
        );
    }

    #[test]
    fn urgent_survives_in_the_open_version() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] fire #urgent\n";
        let out = sweep(s);
        assert!(out.contains("- [ ] fire #urgent\n"), "{out}");
    }

    // No section, nothing to sweep: a sheet the migration has not reached is left as it is.
    #[test]
    fn a_sheet_with_no_section_is_refused() {
        let legacy = "# d\nVersion: v0.0.1\n\n## Wave 1 - verify\n- [ ] check it\n";
        assert!(sweep_sheet(legacy, &ctx()).is_none());
    }

    /// The sweep every `ptask` write ends with moves rows and rewrites none: a caller holding a
    /// row's bytes (`--exact`, the hub, agent-web) still finds it after another write. The
    /// rewriting pass over the same sheet changes those rows, the control that the fixture has
    /// something to rewrite.
    #[test]
    fn the_write_pass_moves_rows_and_keeps_their_bytes() {
        let sheet = "Version: v0.12.1\n\n## Tasks\n\
- [ ] untagged <!-- id:w-1 -->\n\
- [ ] closed release #v0.12.0 #high <!-- id:w-2 -->\n\
- [ ] later and urgent #urgent #v0.12.2 <!-- id:w-3 -->\n\
- [ ] tags out of order #size/s #low <!-- id:w-4 -->\n";
        let rows: Vec<&str> = sheet.lines().filter(|l| l.starts_with("- [ ] ")).collect();
        let write = Ctx {
            rewrite: false,
            ..ctx()
        };
        let moved = sweep_sheet(sheet, &write).expect("the layout changes").0;
        assert!(moved.contains("### Backlog\n"), "{moved}");
        for row in &rows {
            assert!(
                moved.lines().any(|l| l == *row),
                "{row} rewritten:\n{moved}"
            );
        }
        let rewritten = sweep(sheet);
        assert!(
            rows.iter().any(|row| !rewritten.lines().any(|l| l == *row)),
            "the rewriting pass changed nothing:\n{rewritten}"
        );
        assert_eq!(ids(&moved), ids(sheet));
    }

    #[test]
    fn a_board_with_no_version_line_keeps_its_tags() {
        let board = "# d\n\n## Tasks\n- [ ] a #v0.0.9\n";
        let (out, _) = sweep_sheet(board, &ctx()).expect("a board sweeps");
        assert_eq!(
            out,
            "# d\n\n## Tasks\n### Backlog\n- [ ] a #v0.0.9\n- [ ] \n\n---\n### Done\n"
        );
    }

    // The migration case: headings of the two layouts before this one are scaffold, removed
    // rather than read as prose and shoved into the task list.
    #[test]
    fn leftover_headings_from_older_layouts_are_removed_not_read_as_prose() {
        let old_layout = "# d\nVersion: v0.1.0\n\n## Tasks\n- [ ] \n\n\
### Urgent\n- [ ] fire #urgent\n\n### High\n- [ ] steady #high\n\n\
### Low\n\n---\n### Done\n- [x] shipped <!-- pr:1 done:2026-11-09 -->\n";
        let out = sweep(old_layout);
        for h in ["### Urgent", "### High", "### Low", "- [ ] ### "] {
            assert!(!out.contains(h), "{h} left:\n{out}");
        }
        assert!(
            pos(&out, "fire") < pos(&out, "steady"),
            "still sorted:\n{out}"
        );
        assert!(out.contains("- [x] shipped <!-- pr:1"), "{out}");
        assert!(sweep_sheet(&out, &ctx()).is_none(), "idempotent:\n{out}");
    }

    /// The sweep every write to an agent board ends with.
    fn agent() -> Ctx {
        Ctx {
            tiered: true,
            rewrite: false,
            ..ctx()
        }
    }

    // The agent board is all the work planned: every open row no item is behind sits under
    // `### Board`, `#low`, size L, tier 3, parents, asks and rows aimed later alike, and the
    // retired `tier:backlog` token goes from open and closed rows. Why: a one-day weight budget
    // parked 586 of 976 playground rows behind rows nobody starts (2026-11-23), and `#low` is
    // planned work too (909 of 973 playground rows): a nice-to-have goes to `improvements.md`.
    #[test]
    fn an_agent_board_lays_every_open_row_on_the_board() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] c #low #c1003 <!-- tier:backlog -->\n- [/] busy #low\n- [ ] a #high #c1001\n\
- [/] run #low <!-- run:1109 -->\n- [ ] later #high #v0.13.0 #c1009\n\
- [ ] b #size/l #c1002 <!-- id:d-2 tier:backlog -->\n\
- [x] gone <!-- tier:backlog done:2026-11-08 -->\n";
        let out = sweep_sheet(s, &agent()).unwrap().0;
        assert_eq!(
            out,
            "# d\nVersion: v0.12.1\n\n## Tasks\n\
### Now\n- [/] run #low <!-- run:1109 -->\n\n\
### Next up\n- [/] busy #low\n\n\
### Board\n- [ ] a #high #c1001\n- [ ] b #size/l #c1002 <!-- id:d-2 -->\n- [ ] c #low #c1003\n\
- [ ] later #high #v0.13.0 #c1009\n\
- [ ] \n\n---\n### Done\n- [x] gone <!-- done:2026-11-08 -->\n"
        );
        assert_eq!(ids(&out), ids(s), "no row leaves the sheet");
        assert!(sweep_sheet(&out, &agent()).is_none(), "settles:\n{out}");
        let bare = "# d\n\n## Tasks\n- [ ] b <!-- tier:backlog -->\n";
        let out = sweep_sheet(bare, &agent()).unwrap().0;
        assert!(out.contains("- [ ] b\n"), "the empty marker goes:\n{out}");
        // NEGATIVE CONTROL: the human sheet has no Board and keeps a token it was given.
        let human = sweep(s);
        assert!(!human.contains("### Board"), "{human}");
        assert!(human.contains(BACKLOG), "{human}");
        assert!(
            pos(&human, "### Backlog") < pos(&human, "- [ ] a "),
            "{human}"
        );
    }

    // The migration case: a sheet laid out under the old tier, a `### Backlog` heading of
    // tokened rows, is re-laid on its first sweep and settles.
    #[test]
    fn an_old_backlog_heading_is_re_laid_on_the_board() {
        let old = "# d\n\n## Tasks\n### Next up\n- [/] busy #low\n\n\
### Board\n- [ ] a #high #c1001\n\n\
### Backlog\n- [ ] b #c1002\n- [ ] c #low #c1003 <!-- tier:backlog -->\n\
- [ ] \n\n---\n### Done\n";
        let out = sweep_sheet(old, &agent()).unwrap().0;
        assert_eq!(
            out,
            "# d\n\n## Tasks\n### Next up\n- [/] busy #low\n\n\
### Board\n- [ ] a #high #c1001\n- [ ] b #c1002\n- [ ] c #low #c1003\n\
- [ ] \n\n---\n### Done\n"
        );
        assert!(sweep_sheet(&out, &agent()).is_none(), "settles:\n{out}");
        // A `### Board` heading is scaffold on the human sheet too, never read as prose.
        let human = sweep(&out);
        assert!(!human.contains("### Board"), "{human}");
        assert_eq!(human.matches("### Backlog").count(), 1, "{human}");
    }

    #[test]
    fn sweeping_a_swept_sheet_is_a_no_op() {
        let once = sweep(SHEET);
        assert!(sweep_sheet(&once, &ctx()).is_none(), "settles:\n{once}");
    }

    // Everything outside the section is passed through untouched.
    #[test]
    fn content_around_the_section_survives() {
        let s = format!("{SHEET}\n## Backlog\n- [ ] not a task\n");
        let out = sweep(&s);
        assert!(out.contains("## Backlog\n- [ ] not a task"), "{out}");
        assert!(out.starts_with("# demo\nVersion: v0.12.1\n"), "{out}");
    }

    // A proof marker is the evidence a task shipped; losing one loses the audit trail.
    #[test]
    fn every_proof_marker_survives_the_sweep() {
        let s = "# d\nVersion: v0.0.2\n\n## Tasks\n\
- [x] a <!-- pr:307 -->\n- [x] b <!-- pr:274,pr:156 -->\n- [ ] c <!-- ask:0ACTm8 -->\n";
        let out = sweep(s);
        for m in [
            "<!-- pr:307 -->",
            "<!-- pr:274,pr:156 -->",
            "<!-- ask:0ACTm8 -->",
        ] {
            assert!(out.contains(m), "lost {m}:\n{out}");
        }
    }

    fn rolled(s: &str, c: &Ctx) -> Vec<String> {
        let lines: Vec<&str> = s.lines().collect();
        old_done(s, c)
            .into_iter()
            .map(|r| md::task_text(lines[r.start]).trim().to_string())
            .collect()
    }

    // What leaves: undated, dropped, past the window, past the cap. What stays: the recent
    // ones, and a close aimed at a later release, which waits for it.
    #[test]
    fn old_done_rolls_off_what_the_window_does_not_keep() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] open\n\
- [x] undated\n- [x] dropped <!-- done:2026-11-09 dup:d-1 -->\n\
- [x] stale <!-- done:2026-11-01 -->\n- [x] fresh <!-- done:2026-11-08 -->\n\
- [x] today <!-- done:2026-11-09 -->\n- [x] later <!-- done:2026-10-01 --> #v0.12.2\n";
        let r = rolled(s, &ctx());
        for gone in ["undated", "dropped", "stale"] {
            assert!(r.iter().any(|t| t.starts_with(gone)), "{gone}: {r:?}");
        }
        for kept in ["fresh", "today", "later", "open"] {
            assert!(!r.iter().any(|t| t.starts_with(kept)), "{kept}: {r:?}");
        }
        // the cap keeps the newest
        let capped = rolled(s, &ctx_with(7, 1));
        assert!(capped.iter().any(|t| t.starts_with("fresh")), "{capped:?}");
        assert!(!capped.iter().any(|t| t.starts_with("today")), "{capped:?}");
    }

    // A box ticked by hand gets today's date; a dated or dropped close, or one already closed
    // and undated in the saved file, is left alone.
    #[test]
    fn stamp_undated_dates_only_hand_ticked_rows() {
        let s = "# d\n\n## Tasks\n- [x] by hand\n- [x] dated <!-- done:2026-11-01 -->\n\
- [x] an old close\n- [ ] open\n\n## Notes\n- [x] not a sheet row\n";
        let saved = s.replace("- [x] by hand", "- [ ] by hand");
        let out = stamp_undated(s, &saved, ctx().today);
        assert!(out.contains("- [x] an old close\n"), "{out}");
        assert!(
            out.contains("- [x] by hand <!-- done:2026-11-09 -->\n"),
            "{out}"
        );
        assert!(
            out.contains("- [x] dated <!-- done:2026-11-01 -->\n"),
            "{out}"
        );
        assert!(out.contains("- [x] not a sheet row\n"), "{out}");
        assert_eq!(stamp_undated(&out, &saved, ctx().today), out, "idempotent");
    }
}

#[cfg(test)]
mod at_tests {
    use super::*;

    #[test]
    fn a_dated_gate_is_the_moment_and_a_plain_one_has_none() {
        let moment = |l: &str| at_dated(l).map(|t| t.to_string());
        assert_eq!(
            moment("- [ ] cut #urgent #at/2026-11-19/1400 <!-- id:x-1 -->").as_deref(),
            Some("2026-11-19 14:00:00")
        );
        assert_eq!(moment("- [ ] timed #at/0600"), None, "no date, no moment");
        assert_eq!(moment("- [ ] bad #at/2026-11-19/2560"), None);
        assert_eq!(
            moment("- [ ] in the marker <!-- #at/2026-11-19/1400 -->"),
            None,
            "a marker is not the row's text"
        );
    }
}
