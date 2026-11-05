//! `notes ptask <name> …` — a project's task list, living on the project SHEET's current
//! `## Wave` section (the first `## Wave…` heading). The project analog of `notes focus`
//! (which is the daily note's `## Focus`): project tasks belong in the project `.md` — the
//! template-driven, version-scoped source of truth — so `notes projects --roll` freezes a
//! REAL task list into `versions/`, and the daily note keeps only the untagged main tasks.
//!
//! Mirrors `focus.rs` verb-for-verb but points the SAME generic `md` helpers at a resolved
//! wave heading instead of the hard-coded `## Focus`. The task SHEET is README.md/tasks.md
//! that carries a `## Wave` — decoupled from the `Version:` line, so a release-managed
//! project (version in `changelog/`) can hold a task sheet without owning its version there.

use crate::agent_sheet::Lane;
use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use crate::project_sweep;
use crate::projects;
use crate::waves;
use anyhow::{bail, Result};
use std::fs;
use std::path::{Path, PathBuf};

/// The current wave's heading TEXT — the FIRST `## Wave…` line's text (e.g.
/// `"Wave: v1.13.0 (current)"`). `md::section_span` matches a heading exactly, so callers
/// resolve the live text rather than assuming a fixed string.
///
/// First, not `(current)`-suffixed: position is the invariant, and it is what makes the
/// planned waves below it invisible to every reader here.
fn current_wave(content: &str) -> Option<String> {
    waves::sections(content).first().map(|s| s.heading.clone())
}

/// The heading of the wave a verb should act on: the named one for `--to/--wave <ver>`,
/// else the current wave. Minting a planned section when `--to` names a version the
/// roadmap does not have yet is the point — that is how you plan forward.
fn target_wave(content: &str, want: Option<&str>, mint: bool) -> Result<(String, Option<String>)> {
    let Some(want) = want else {
        let h = current_wave(content)
            .ok_or_else(|| anyhow::anyhow!("no `## Wave` section on the sheet"))?;
        return Ok((h, None));
    };
    let ver = waves::parse(want.trim())
        .ok_or_else(|| anyhow::anyhow!("not a version: '{want}' (want vX.Y.Z)"))?;
    if let Some(s) = waves::find(content, ver) {
        return Ok((s.heading, None));
    }
    if !mint {
        bail!(
            "no wave {} on the sheet — plan it first with `add --to {}`",
            waves::fmt(ver),
            waves::fmt(ver)
        );
    }
    let grown = waves::insert_planned(content, ver);
    let heading = waves::find(&grown, ver)
        .map(|s| s.heading)
        .ok_or_else(|| anyhow::anyhow!("could not open wave {}", waves::fmt(ver)))?;
    Ok((heading, Some(grown)))
}

/// The project's TASK sheet: `README.md` then `tasks.md`, whichever carries a `## Wave`.
///
/// `pub(crate)` because carrying a live sheet is also how cross-org name resolution picks
/// between two orgs holding the same slug (`projects::project_dir`) — the same rule
/// `lab_project_root` applies on the shell side, kept identical so both agree on which copy
/// is the real one.
pub(crate) fn task_sheet(dir: &Path) -> Option<PathBuf> {
    ["README.md", "tasks.md"].iter().find_map(|n| {
        let p = dir.join(n);
        fs::read_to_string(&p)
            .ok()
            .filter(|c| current_wave(c).is_some())
            .map(|_| p)
    })
}

/// Resolve (or create) a project's task sheet. Prefers an existing `## Wave` sheet; else
/// appends a wave to an existing `README.md`; else scaffolds a fresh `README.md` task
/// sheet. `name` seeds the title of a fresh sheet.
///
/// The wave is NAMED for the sheet's `Version:` line via `waves::heading_current` — the
/// same minter `projects::sheet_body` uses. This path used to hardcode the literal string
/// `new`, which is how a sheet could read `## Wave: new (current)` directly under
/// `Version: v0.0.2`: the version is meant to be the wave's only id, and a wave created
/// through here had no id at all.
fn ensure_task_sheet(dir: &Path, name: &str) -> Result<PathBuf> {
    if let Some(s) = task_sheet(dir) {
        return Ok(s);
    }
    let readme = dir.join("README.md");
    if let Ok(mut c) = fs::read_to_string(&readme) {
        if !c.ends_with('\n') {
            c.push('\n');
        }
        let heading = waves::heading_current(&projects::wave_version_of(&c));
        c.push_str(&format!("\n## {heading}\n- [ ] \n"));
        md::write_atomic(&readme, &c)?;
    } else {
        // No sheet at all, so no `Version:` line to read: a fresh sheet opens at v0.0.1,
        // matching what `projects --new` seeds.
        let heading = waves::heading_current("v0.0.1");
        fs::write(&readme, format!("# {name}\n\n## {heading}\n- [ ] \n"))?;
    }
    Ok(readme)
}

/// A project directory's current wave: `(version, open_task_lines)`. `None` when the dir
/// has no task sheet at all.
///
/// Keyed by DIRECTORY rather than profile+name, unlike `sheet_and_wave` below, because the
/// board walks `daily::discover_project_dirs` across every configured profile — it already
/// holds the path and has no name to re-resolve. Same sheet, same `## Wave`, same open-task
/// predicate the cockpit and `ptask list` use, so the three cannot disagree about what is
/// on a board.
pub(crate) fn open_wave_for_dir(dir: &Path) -> Option<(String, Vec<String>)> {
    let w = open_wave_rows(dir)?;
    Some((w.version, w.rows.into_iter().map(|(_, l)| l).collect()))
}

/// A sheet's current wave as `notes board --json` reads it: where the sheet is, its version,
/// and each open row with its 1-based line number.
pub(crate) struct OpenWave {
    pub sheet: PathBuf,
    pub version: String,
    pub rows: Vec<(usize, String)>,
}

/// [`open_wave_for_dir`] with the sheet path and line numbers kept. The one reader both use,
/// so the JSON feed and the rendered board cannot list different rows.
pub(crate) fn open_wave_rows(dir: &Path) -> Option<OpenWave> {
    let sheet = task_sheet(dir)?;
    let content = fs::read_to_string(&sheet).ok()?;
    let heading = current_wave(&content)?;
    let rows = md::section_numbered(&content, &heading)
        .into_iter()
        .filter(|(_, l)| md::is_open_task(l))
        .map(|(n, l)| (n, l.trim_end().to_string()))
        .collect();
    Some(OpenWave {
        version: projects::wave_version_of(&content),
        sheet,
        rows,
    })
}

/// The directory a verb acts in: the project's own, or its agent board's.
///
/// Every verb resolves through here so `--agent` is one decision made once, rather than a
/// path choice repeated at eight call sites that can each get it wrong.
fn lane_dir(p: &Profile, name: &str, lane: Lane) -> Result<PathBuf> {
    Ok(lane.dir(&projects::project_dir(p, name)?))
}

/// The sheet + its resolved current-wave heading, for a named project. `None` when the
/// project has no task sheet yet (a read verb then lists nothing).
fn sheet_and_wave(
    p: &Profile,
    name: &str,
    lane: Lane,
) -> Result<Option<(PathBuf, String, String)>> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        return Ok(None);
    };
    let content = fs::read_to_string(&sheet)?;
    match current_wave(&content) {
        Some(h) => Ok(Some((sheet, h, content))),
        None => Ok(None),
    }
}

/// An open wave task matching `query` (already lower-cased) — the shared predicate for
/// `done`/`start`/`rm`, matching `focus.rs::is_match`.
pub(crate) fn is_match(line: &str, query: &str) -> bool {
    md::is_open_task(line) && md::task_key(line).contains(query)
}

/// Which row a verb acts on: the first open task whose text contains some words, the open
/// task carrying an id (a query shaped like one, `ar-142`), or the one open task whose line
/// is exactly `raw`.
///
/// `Exact` is for a UI. It shows a row from `notes board --json` and acts on that row's `raw`
/// field, so the write is optimistic concurrency without id stamps in the sheets: when the
/// line was edited, ticked or removed since the UI read it, nothing matches, nothing is
/// written, and the verb exits 1 so the UI refreshes. Words could hit a different row.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Pick {
    Words(String),
    Id(String),
    Exact(String),
}

impl Pick {
    /// The pick for `query`, refusing an empty one: an empty query matches every row.
    pub(crate) fn new(query: &str, exact: bool) -> Result<Pick> {
        if exact {
            let raw = query.trim_end();
            if !md::is_open_task(raw) {
                bail!("--exact takes a whole open task line, as `notes board --json` prints it in `raw`");
            }
            return Ok(Pick::Exact(raw.to_string()));
        }
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            bail!("which one? (provide a word from the task)");
        }
        if md::is_row_id(&q) {
            return Ok(Pick::Id(q));
        }
        Ok(Pick::Words(q))
    }

    /// Whether `line` is the row this pick names.
    pub(crate) fn hits(&self, line: &str) -> bool {
        match self {
            Pick::Words(q) => is_match(line, q),
            Pick::Id(id) => md::is_open_task(line) && md::row_id(line).as_deref() == Some(id),
            Pick::Exact(raw) => md::is_open_task(line) && line.trim_end() == raw,
        }
    }

    /// Refuse an exact pick whose line is on `sheet` more than once. Twin rows cannot be
    /// told apart by their text, and the verb would act on whichever comes first, which may
    /// sit in another wave than the one the UI showed. A missing sheet passes: the verb
    /// itself reports that.
    pub(crate) fn sole_in(&self, sheet: &Path) -> Result<()> {
        if let Pick::Exact(raw) = self {
            let n = fs::read_to_string(sheet)
                .map(|c| c.lines().filter(|l| self.hits(l)).count())
                .unwrap_or(0);
            if n > 1 {
                bail!(
                    "'{raw}' is on {} {n} times; --exact cannot tell twins apart, so nothing was written (edit one by hand)",
                    sheet.display()
                );
            }
        }
        Ok(())
    }
}

/// The task sheet a ptask verb on `name` and `lane` reads, if the project has one.
pub(crate) fn sheet_of(p: &Profile, name: &str, lane: Lane) -> Result<Option<PathBuf>> {
    Ok(task_sheet(&lane_dir(p, name, lane)?))
}

impl std::fmt::Display for Pick {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Pick::Words(q) | Pick::Id(q) | Pick::Exact(q) => f.write_str(q),
        }
    }
}

/// `notes ptask <name> list [--wave vX.Y.Z | --all]` — TSV of OPEN tasks.
///
/// Bare `list` is the current wave and emits exactly the four columns it always has —
/// `path<TAB>line<TAB>key<TAB>text` - because the cockpit parses it. A
/// wave SELECTOR adds a fifth column (the wave's version) rather than changing the first
/// four, so a reader that only wants `$1..$4` is unaffected either way.
pub fn list(p: &Profile, name: &str, wave: Option<&str>, all: bool, lane: Lane) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        return Ok(0);
    };
    let content = fs::read_to_string(&sheet)?;
    let file = sheet.display();

    if !all && wave.is_none() {
        let Some(heading) = current_wave(&content) else {
            return Ok(0);
        };
        for (n, l) in md::section_numbered(&content, &heading) {
            if md::is_open_task(l) {
                println!("{file}\t{n}\t{}\t{}", md::task_key(l), l.trim_end());
            }
        }
        return Ok(0);
    }

    let want = match wave {
        Some(w) => Some(
            waves::parse(w.trim())
                .ok_or_else(|| anyhow::anyhow!("not a version: '{w}' (want vX.Y.Z)"))?,
        ),
        None => None,
    };
    for s in waves::sections(&content) {
        if want.is_some() && s.version != want {
            continue;
        }
        for (n, l) in md::section_numbered(&content, &s.heading) {
            if md::is_open_task(l) {
                println!(
                    "{file}\t{n}\t{}\t{}\t{}",
                    md::task_key(l),
                    l.trim_end(),
                    s.label()
                );
            }
        }
    }
    Ok(0)
}

/// `notes ptask <name> add <text> [--to vX.Y.Z]` — add `- [ ] <text>` to a wave, creating
/// the task sheet if the project has none.
///
/// Without `--to` this is the current wave, exactly as before. With it, the task goes to a
/// PLANNED wave — minted in version order below the current one if the roadmap does not
/// hold it yet. That is the whole roadmap-forward loop: plan into `v1.14.0` while `v1.13.0`
/// is still running, and the roll promotes it when v1.13.0 closes.
///
/// The row is stamped as README "The task row" says: its created tag (`#cMMDD`), the default
/// priority when it has none, and its id (`<!-- id:<code>-<n> -->`, [`next_id`]) when the
/// registry gives the project a `code`. Each of `details` becomes an indented line under it.
pub fn add(
    p: &Profile,
    log: &Logger,
    name: &str,
    text: &str,
    details: &[String],
    to: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text)");
    }
    let proj_dir = projects::project_dir(p, name)?;
    let sheet = match lane {
        Lane::Human => ensure_task_sheet(&proj_dir, name)?,
        Lane::Agent => crate::agent_sheet::ensure_for(p, &proj_dir, name)?,
    };
    let content = fs::read_to_string(&sheet)?;
    let (heading, grown) = target_wave(&content, to, true)?;
    let base = grown.unwrap_or(content);
    let today = chrono::Local::now().date_naive();
    let mut line = md::stamp_line(
        &md::with_default_priority(&format!("- [ ] {text}")),
        today,
        today,
    );
    match crate::registry::Registry::load().and_then(|r| r.code(name)) {
        Some(code) => line = md::add_marker(&line, &format!("id:{}", next_id(&proj_dir, &code))),
        None => eprintln!(
            "(no id: '{name}' has no `code` in project-map.json trackers; the row is unaddressable by id)"
        ),
    }
    let mut block = vec![line.clone()];
    block.extend(md::detail_lines("", details));
    let new = md::insert_under_heading(&base, &heading, &block);
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("added to {} ({name})", sheet.display()));
    for l in &block {
        println!("{l}");
    }
    if to.is_some() {
        println!("  -> {heading}");
    }
    Ok(0)
}

/// The next row id for a project: `<code>-<n>`, `n` one past the highest `id:<code>-N` on any
/// `.md` file under its dir (both lanes, playtest and `versions/`). A dropped row keeps its
/// id on the sheet and an archived one keeps it in `versions/`, so an id is never reused.
pub(crate) fn next_id(proj_dir: &Path, code: &str) -> String {
    let needle = format!("id:{code}-");
    let mut max = 0u64;
    let mut stack = vec![proj_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for e in entries.flatten() {
            let path = e.path();
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                stack.push(path);
            } else if path.extension().is_some_and(|x| x == "md") {
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                for (i, _) in text.match_indices(&needle) {
                    let digits: String = text[i + needle.len()..]
                        .chars()
                        .take_while(char::is_ascii_digit)
                        .collect();
                    max = max.max(digits.parse().unwrap_or(0));
                }
            }
        }
    }
    format!("{code}-{}", max + 1)
}

/// `notes ptask <name> move <query> --to vX.Y.Z` — move the first open task matching
/// `<query>` from whatever wave holds it into `<ver>`, minting that wave if it is new.
///
/// The verb that splits a pile into a roadmap, and the one the roll gate points at: a
/// version that still has open work does not close, so either finish the task or say
/// explicitly which version it belongs to instead.
pub fn move_task(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    to: &str,
    lane: Lane,
) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    let content = fs::read_to_string(&sheet)?;
    let (heading, grown) = target_wave(&content, Some(to), true)?;
    let content = grown.unwrap_or(content);

    let Some((new, line, from)) = move_within(&content, pick, &heading, to)? else {
        eprintln!("no open task matches '{pick}' outside {heading} in {name}");
        return Ok(1);
    };
    md::write_atomic(&sheet, &new)?;
    log.info(
        "ptask",
        &format!("moved to {heading} in {} ({name})", sheet.display()),
    );
    println!("moved {}\n  {from} -> {heading}", line.trim());
    Ok(0)
}

/// Pure core of the same-sheet `move`: lift the first open row matching `query` out of any
/// wave other than `heading` and insert it, retagged for `to`, under `heading`. Returns
/// `(new_content, moved_line, source_heading)`, or `None` when nothing outside the target
/// matches.
fn move_within(
    content: &str,
    pick: &Pick,
    heading: &str,
    to: &str,
) -> Result<Option<(String, String, String)>> {
    // Find it in any wave EXCEPT the target, so a move onto its own wave is a clear no-op
    // rather than a silent delete-and-reinsert.
    let Some((from, line)) = find_open(content, pick, Some(heading)) else {
        return Ok(None);
    };
    let Some((cut, _)) = md::edit_first_in_section(content, &from, |l| pick.hits(l), |_| None)
    else {
        bail!("could not lift '{pick}' out of {from}");
    };
    // Retag to the target, as `demote` does. The row keeping its old `#v` tag is how a moved
    // task got dragged straight back by the next `sweep`, which buckets by tag.
    let line = retag_for(&cut, &line, to);
    let new = md::insert_under_heading(&cut, heading, std::slice::from_ref(&line));
    Ok(Some((new, line, from)))
}

/// The first open row matching `query` (lower-cased) in wave order, skipping the wave
/// headed `skip`: `(source heading, line)`. The one search both forms of `move` use, so
/// "which row does `move <query>` take" has a single answer.
fn find_open(content: &str, pick: &Pick, skip: Option<&str>) -> Option<(String, String)> {
    for s in waves::sections(content) {
        if Some(s.heading.as_str()) == skip {
            continue;
        }
        if let Some((_, l)) = md::section_numbered(content, &s.heading)
            .into_iter()
            .find(|(_, l)| pick.hits(l))
        {
            return Some((s.heading.clone(), l.trim_end().to_string()));
        }
    }
    None
}

/// `notes ptask <src> move <query> --project <dest> [--to vX.Y.Z]` - move the first open
/// row matching `<query>` off SRC's sheet and onto DEST's: its current wave, or the wave
/// `--to` names. How a catch-all sheet gets split into per-project ones without hand-editing.
///
/// DEST resolves through `projects::project_dir` like every other name here, so it may live
/// in another profile. Unlike the same-project form this never MINTS a wave: which version
/// something ships in on another project's roadmap is that project's call, so a `--to` the
/// dest sheet does not already hold is refused. `--agent` works because both ends go through
/// the same `lane_dir`: agent sheet to agent sheet.
pub fn move_to_project(
    p: &Profile,
    log: &Logger,
    src: &str,
    dest: &str,
    pick: &Pick,
    to: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let src_dir = lane_dir(p, src, lane)?;
    let dest_dir = lane_dir(p, dest, lane)?;
    let Some(src_sheet) = task_sheet(&src_dir) else {
        bail!("'{src}' has no task sheet yet - nothing to move");
    };
    let Some(dest_sheet) = task_sheet(&dest_dir) else {
        let flag = if lane == Lane::Agent { " --agent" } else { "" };
        bail!("'{dest}' has no task sheet with a `## Wave` to move into - add one with `notes ptask {dest}{flag} add \"...\"`");
    };
    let Some(moved) = transfer(&src_sheet, &dest_sheet, pick, to)? else {
        eprintln!("no open task matches '{pick}' in {src}");
        return Ok(1);
    };
    log.info(
        "ptask",
        &format!(
            "moved from {} ({src}) to {} in {} ({dest})",
            src_sheet.display(),
            moved.into,
            dest_sheet.display()
        ),
    );
    println!(
        "moved {}\n  {src}: {} -> {dest}: {}",
        moved.line.trim(),
        moved.from,
        moved.into
    );
    Ok(0)
}

/// What a cross-project move did: both sheets' new text, the row as it landed, and the
/// wave headings it left and joined.
#[derive(Debug)]
struct Lifted {
    src: String,
    dest: String,
    line: String,
    from: String,
    into: String,
}

/// File half of `move_to_project`: read both sheets, compute both edits, then write.
///
/// Every refusal happens before the first write. The DEST is written first and the SRC
/// second, because if the second write fails the row then exists on BOTH sheets (a
/// duplicate you can see and `rm`) rather than on NEITHER (a task silently gone).
fn transfer(
    src_sheet: &Path,
    dest_sheet: &Path,
    pick: &Pick,
    to: Option<&str>,
) -> Result<Option<Lifted>> {
    let same = match (src_sheet.canonicalize(), dest_sheet.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => src_sheet == dest_sheet,
    };
    if same {
        bail!(
            "source and destination are the same sheet - use `move --to <VERSION>` to change waves"
        );
    }
    let src = fs::read_to_string(src_sheet)?;
    let dest = fs::read_to_string(dest_sheet)?;
    let Some(moved) = lift_into(&src, &dest, pick, to)? else {
        return Ok(None);
    };
    md::write_atomic(dest_sheet, &moved.dest)?;
    md::write_atomic(src_sheet, &moved.src).map_err(|e| {
        anyhow::anyhow!(
            "{e}\n  the row was ADDED to {} but not removed from {} - `rm` it there",
            dest_sheet.display(),
            src_sheet.display()
        )
    })?;
    Ok(Some(moved))
}

/// Pure core of a cross-project move: the first open row matching `query` in `src` (any
/// wave, in order - the same search the same-sheet `move` runs), cut from `src` and
/// inserted into `dest`'s current wave or its existing wave `to`. `None` on no match.
fn lift_into(src: &str, dest: &str, pick: &Pick, to: Option<&str>) -> Result<Option<Lifted>> {
    // Resolve the destination before looking at the source: a dest with no wave to land
    // in is the refusal, whether or not the query would have matched.
    let (into, _) = target_wave(dest, to, false)?;
    let Some((from, line)) = find_open(src, pick, None) else {
        return Ok(None);
    };
    let Some((cut, _)) = md::edit_first_in_section(src, &from, |l| pick.hits(l), |_| None) else {
        bail!("could not lift '{pick}' out of {from}");
    };
    let line = retag_into(dest, &into, &line);
    let grown = md::insert_under_heading(dest, &into, std::slice::from_ref(&line));
    Ok(Some(Lifted {
        src: cut,
        dest: grown,
        line,
        from,
        into,
    }))
}

/// `line` retagged for the wave headed `heading` on `dest`. The source project's `#v` tag
/// means nothing on another project's roadmap, so a dest wave with no parseable version
/// strips it rather than keeping it.
fn retag_into(dest: &str, heading: &str, line: &str) -> String {
    match waves::sections(dest)
        .into_iter()
        .find(|s| s.heading == heading)
        .and_then(|s| s.version)
    {
        Some(v) => retag_for(dest, line, &waves::fmt(v)),
        None => md::split_wave(line).0,
    }
}

/// `line` retagged for the wave `to` on `content`, keeping `#urgent` only when `to` is the
/// current wave. Unchanged when `to` is not a version.
fn retag_for(content: &str, line: &str, to: &str) -> String {
    let Some(v) = waves::parse(to.trim()) else {
        return line.to_string();
    };
    let is_cur = waves::current_of(content, projects::sheet_version(content))
        .and_then(|s| s.version)
        == Some(v);
    project_sweep::retag_wave(line, v, is_cur).0
}

/// `notes ptask <name> promote|demote <query>` - step the first matching task one wave
/// sooner or later, the way `<leader>tP`/`tp` steps a priority.
///
/// This is the verb the roadmap was missing. `move --to vX.Y.Z` needs an absolute version
/// typed out, so in practice nothing ever left the current wave and 13 of 14 sheets have no
/// planned wave at all. A relative step costs nothing to reach for, which is what makes
/// splitting a pile into small waves something you actually do.
///
/// `promote` clamps at the current wave and exits NON-ZERO there: the cockpit drives these
/// through fzf `execute-silent`, which discards stdout, so a zero exit would render "there is
/// nothing sooner" as silence.
pub fn step(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    dir: i32,
    lane: Lane,
) -> Result<i32> {
    let dir_word = if dir < 0 { "promote" } else { "demote" };
    let dir_proj = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir_proj) else {
        bail!("'{name}' has no task sheet yet - add one with `notes ptask {name} add \"...\"`");
    };
    let content = fs::read_to_string(&sheet)?;
    let secs = waves::sections(&content);
    let cur = waves::current_of(&content, projects::sheet_version(&content))
        .and_then(|s| s.version)
        .ok_or_else(|| anyhow::anyhow!("{name}'s sheet has no versioned `## Wave` section"))?;
    let ladder: Vec<(u32, u32, u32)> = secs.iter().filter_map(|s| s.version).collect();

    // Which wave holds it now: the tag if it has one, else the section it sits in.
    let mut at: Option<((u32, u32, u32), String, String)> = None; // (version, heading, line)
    for s in &secs {
        let Some(sv) = s.version else { continue };
        if let Some((_, l)) = md::section_numbered(&content, &s.heading)
            .into_iter()
            .find(|(_, l)| pick.hits(l))
        {
            let tagged = md::wave_tag(l).and_then(|t| waves::parse(t.trim_start_matches('#')));
            at = Some((
                tagged.unwrap_or(sv),
                s.heading.clone(),
                l.trim_end().to_string(),
            ));
            break;
        }
    }
    let Some((at_v, from, line)) = at else {
        eprintln!("no open task matches '{pick}' in {name}");
        return Ok(1);
    };

    let to = match project_sweep::step_wave(cur, &ladder, at_v, dir) {
        Ok(v) => v,
        Err(project_sweep::StepEnd::AtCurrent) => {
            eprintln!(
                "'{}' is already in {} - nothing sooner than the current wave",
                md::task_text(&line),
                waves::fmt(cur)
            );
            return Ok(1);
        }
    };

    let (retagged, note) = project_sweep::retag_wave(&line, to, to == cur);
    let heading = waves::heading_current(&waves::fmt(to));
    let (content, heading) = match waves::find(&content, to) {
        Some(s) => (content, s.heading),
        // The wave does not exist yet: open it as PLANNED, below the current one.
        None => (waves::insert_planned(&content, to), {
            let _ = heading;
            waves::heading_planned(&waves::fmt(to))
        }),
    };
    let Some((cut, _)) = md::edit_first_in_section(&content, &from, |l| pick.hits(l), |_| None)
    else {
        bail!("could not lift '{pick}' out of {from}");
    };
    let new = md::insert_under_heading(&cut, &heading, std::slice::from_ref(&retagged));
    md::write_atomic(&sheet, &new)?;
    log.info(
        "ptask",
        &format!("{dir_word}d to {heading} in {} ({name})", sheet.display()),
    );
    println!("{} {}", dir_word, md::task_text(&line));
    println!("  {} -> {}", waves::fmt(at_v), waves::fmt(to));
    if let Some(n) = note {
        println!("  {n}");
    }
    Ok(0)
}

/// `notes ptask <name> done <query> (--proof <ref> | --unverified "<why>")` — check off the
/// first open wave task matching `<query>`, and record WHY it counts as done.
///
/// Done needs evidence. A bare `done` is rejected because "closed" and "finished" drifted
/// apart everywhere they were allowed to: the roll gate above only means something if the
/// checkboxes it counts mean something. Two doors, deliberately:
///
/// - `--proof <ref>` — something checkable later: `pr:1142`, `run:<id>`, a URL. Stamped
///   into the line's marker comment beside any existing `vk:`/`ask:` id.
/// - `--unverified "<why>"` — no checkable artifact exists. Also stamped, and visibly so,
///   because the failure mode of a proof field is not people lying in it, it is people
///   leaving it blank until it means nothing. The manual walk has the same
///   instinct: `n/a - <why>` mandatory rather than blank.
///
/// Either way the row lands in the version's agent note (`agent/versions/<vX.Y.Z>.md`), which is what
/// turns a pile of ticked boxes into an evidence trail somebody can audit.
pub fn done(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    proof: Option<&str>,
    unverified: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let stamp = proof_stamp(proof, unverified)?;
    Ok(edit(p, log, name, pick, "done", lane, |l| {
        Some(md::add_marker(&md::set_checkbox(l, 'x'), &stamp))
    })?
    .0)
}

/// The marker text a `done` will stamp, or the error explaining that it needs one.
///
/// The gate itself, kept out of `done` so it is testable without a vault. A bare `done`
/// must FAIL: the roll gate above only means something if a ticked checkbox does.
pub(crate) fn proof_stamp(proof: Option<&str>, unverified: Option<&str>) -> Result<String> {
    match (proof, unverified) {
        (Some(_), Some(_)) => bail!("--proof and --unverified are alternatives; pick one"),
        (Some(r), None) if !r.trim().is_empty() => Ok(r.trim().to_string()),
        (None, Some(w)) if !w.trim().is_empty() => Ok(format!("unverified: {}", w.trim())),
        _ => bail!(
            "done needs proof. one of:\n  \
             --proof pr:1142          a merged PR, a run id, a URL - something checkable\n  \
             --unverified \"<why>\"     no checkable artifact, and this says so out loud"
        ),
    }
}

/// `notes ptask <name> drop --why "<why>" | --dup <id> <query>` - close the first matching open
/// wave task undelivered. The row stays, ticked, with `dropped: <why>` or `dup:<id>` in its
/// marker, so its id is never reused, its detail lines stay under it, and the sweep and roll
/// treat it as any closed row. There is no delete.
pub fn drop(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    why: Option<&str>,
    dup: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let stamp = drop_stamp(why, dup)?;
    Ok(edit(p, log, name, pick, "dropped", lane, move |l| {
        Some(md::add_marker(&md::set_checkbox(l, 'x'), &stamp))
    })?
    .0)
}

/// The marker a `drop` stamps, or the error saying it needs a reason.
pub(crate) fn drop_stamp(why: Option<&str>, dup: Option<&str>) -> Result<String> {
    match (why.map(str::trim), dup.map(str::trim)) {
        (Some(_), Some(_)) => bail!("--why and --dup are alternatives; pick one"),
        (Some(w), None) if !w.is_empty() => Ok(format!("dropped: {w}")),
        (None, Some(d)) if md::is_row_id(d) => Ok(format!("dup:{d}")),
        (None, Some(d)) => {
            bail!("--dup takes the id of the row this one duplicates (like ar-142), not '{d}'")
        }
        _ => bail!(
            "drop needs a reason. one of:\n  \
             --why \"<why>\"   stale, superseded, moved to its home (\"moved: ideas.md\")\n  \
             --dup <id>      the row it duplicates"
        ),
    }
}

/// `notes ptask <name> edit <query> --text|--append` - change the first matching wave task's
/// text in place: replace it, or add `append` to the end of it. Its place on the sheet, its
/// checkbox state and its tags stay as they were ([`md::retext_task`]).
///
/// Each of `details` becomes an indented line at the end of the row's block, after its
/// existing detail lines and child rows. `--detail` alone leaves the row's own line as it is.
#[allow(clippy::too_many_arguments)]
pub fn retext(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    text: Option<&str>,
    append: Option<&str>,
    details: &[String],
    lane: Lane,
) -> Result<i32> {
    let (text, append) = (text.map(str::trim), append.map(str::trim));
    let has_details = details.iter().any(|d| !d.trim().is_empty());
    if text.or(append).is_none_or(str::is_empty) && !has_details {
        bail!("edit needs the new words: --text \"<new text>\", --append \"<more>\" or --detail \"<line>\"");
    }
    if has_details {
        let Some((sheet, heading, content)) = sheet_and_wave(p, name, lane)? else {
            bail!("'{name}' has no task sheet yet");
        };
        let Some(new) = md::append_details(&content, &heading, |l| pick.hits(l), details) else {
            eprintln!("no open task matches '{pick}' in {name}");
            return Ok(1);
        };
        md::write_atomic(&sheet, &new)?;
        log.info(
            "ptask",
            &format!("detailed in {} ({name})", sheet.display()),
        );
        if text.or(append).is_none_or(str::is_empty) {
            println!("detailed '{pick}'");
            return Ok(0);
        }
    }
    Ok(edit(p, log, name, pick, "edited", lane, |l| {
        let new = match (text, append) {
            (Some(t), _) => t.to_string(),
            (None, Some(a)) => format!("{} {a}", md::task_text(l)),
            (None, None) => unreachable!("checked above"),
        };
        Some(md::retext_task(l, &new))
    })?
    .0)
}

/// `notes ptask <name> start <query>` - toggle the first matching wave task between todo
/// (`[ ]`) and in-progress (`[/]`).
///
/// A row going to `[/]` with no id gets one, as [`add`] would have given it: a started row has
/// a queue item, and the item joins its row by that id, which survives a retext. The new id
/// goes on its own `  id:<id>` line after the usual output, so `fleet-dispatch` can read it.
pub fn start(p: &Profile, log: &Logger, name: &str, pick: &Pick, lane: Lane) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
    let id = crate::registry::Registry::load()
        .and_then(|r| r.code(name))
        .map(|code| next_id(&dir, &code));
    let (code, matched) = edit(p, log, name, pick, "toggled", lane, |l| {
        Some(toggle_started(l, id.as_deref()))
    })?;
    if let (Some(line), Some(id)) = (matched, id) {
        if toggle_started(&line, Some(&id)).contains(&format!("id:{id}")) {
            println!("  id:{id}");
        }
    }
    Ok(code)
}

/// One row through `start`: `[/]` goes back to `[ ]` as it is; anything else goes to `[/]`,
/// stamped with `id` when it carries none.
fn toggle_started(line: &str, id: Option<&str>) -> String {
    if line.trim_start().starts_with("- [/]") {
        return md::set_checkbox(line, ' ');
    }
    let started = md::set_checkbox(line, '/');
    match id.filter(|_| md::row_id(line).is_none()) {
        Some(id) => md::add_marker(&started, &format!("id:{id}")),
        None => started,
    }
}

/// `notes ptask <name> sweep [--dry-run]` - reorganize the sheet's wave roadmap.
///
/// Logs under `ptask:` like every other verb here, because the Stop gate greps the notes log
/// for `(focus|ptask):` to decide a turn made progress; a verb logged under anything else is
/// invisible to it and the session gets blocked for work it did.
pub fn sweep(p: &Profile, log: &Logger, name: &str, dry_run: bool, lane: Lane) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        bail!("{name} has no task sheet with a `## Wave` section");
    };
    let content = fs::read_to_string(&sheet)?;
    let Some((new, report)) = project_sweep::sweep_sheet(&content) else {
        println!(
            "{}: already swept (or no `Version:` / an unversioned wave heading)",
            name
        );
        return Ok(0);
    };
    for r in &report {
        println!("{r}");
    }
    if dry_run {
        println!("--dry-run: {} would change", sheet.display());
        return Ok(0);
    }
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("swept {name}'s waves"));
    println!("{}", sheet.display());
    Ok(0)
}

/// The done rows on a sheet, as line ranges: each top-level checked task with the indented
/// lines under it. A checked subtask under an open row is part of that row and stays.
pub(crate) fn done_rows(content: &str) -> Vec<std::ops::Range<usize>> {
    let lines: Vec<&str> = content.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i];
        if !(l.starts_with("- [") && md::is_checked(l)) {
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < lines.len()
            && !lines[end].trim().is_empty()
            && lines[end].starts_with([' ', '\t'])
        {
            end += 1;
        }
        out.push(i..end);
        i = end;
    }
    out
}

/// Put `rows` at the end of the agent note's `## Done rows` section, adding the section
/// at the foot of the note when it has none.
fn append_done_rows(content: &str, rows: &[String]) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    match md::section_span(&lines, "Done rows") {
        Some(span) => {
            // after the section's last non-blank line, so the rows stay one list
            let at = lines[span.clone()]
                .iter()
                .rposition(|l| !l.trim().is_empty())
                .map_or(span.start, |k| span.start + k + 1);
            for (k, r) in rows.iter().enumerate() {
                out.insert(at + k, r.clone());
            }
        }
        None => {
            while out.last().is_some_and(|l| l.trim().is_empty()) {
                out.pop();
            }
            out.push(String::new());
            out.push("## Done rows".to_string());
            out.extend(rows.iter().cloned());
        }
    }
    format!("{}\n", out.join("\n"))
}

/// `notes ptask <name> --agent archive [--dry-run]` - move the agent board's done rows into
/// `agent/versions/<vX.Y.Z>.md`, the note `done` writes their proof into (the human sheet's
/// open version), under `## Done rows`, verbatim and in board order.
///
/// What keeps an agent board inside its budget (`notes doctor --projects`). The human
/// sheet has no archive: its done rows freeze with its version in `notes projects --roll`.
pub fn archive(p: &Profile, log: &Logger, name: &str, dry_run: bool, lane: Lane) -> Result<i32> {
    if lane == Lane::Human {
        bail!(
            "archive moves the agent board's done rows (--agent); the human sheet's done rows freeze with `notes projects --roll`"
        );
    }
    let dir = projects::project_dir(p, name)?;
    let board = crate::agent_sheet::sheet_path(&dir);
    let Ok(content) = fs::read_to_string(&board) else {
        bail!("{name} has no agent board ({})", board.display());
    };
    let ranges = done_rows(&content);
    if ranges.is_empty() {
        println!("{name}: no done rows on the agent board");
        return Ok(0);
    }
    let ver = task_sheet(&dir)
        .and_then(|s| fs::read_to_string(s).ok())
        .map_or_else(|| "v0.0.1".to_string(), |c| projects::wave_version_of(&c));
    let note = projects::agent_note_path(&dir, &ver);
    if dry_run {
        println!(
            "--dry-run: {} done rows would move from {} to {}",
            ranges.len(),
            board.display(),
            note.display()
        );
        return Ok(0);
    }

    // The note first: a failure between the two writes leaves rows in both, never neither.
    let (kept, n) = archive_done_rows(&dir, name, &ver, &content)?;
    md::write_atomic(&board, &kept)?;
    log.info(
        "ptask",
        &format!("archived {n} done rows ({name}) -> {}", note.display()),
    );
    println!("moved {n} done rows -> {}", note.display());
    Ok(0)
}

/// Append a board's done rows to `agent/versions/<ver>.md` under `## Done rows` and return
/// the board without them, plus how many moved. Writes the note only; the caller writes the
/// board after, so a failure between the two leaves rows in both, never neither.
///
/// Shared by `ptask --agent archive` and `notes projects --roll`, which closes a version's
/// agent board with it.
pub(crate) fn archive_done_rows(
    dir: &Path,
    name: &str,
    ver: &str,
    content: &str,
) -> Result<(String, usize)> {
    let ranges = done_rows(content);
    if ranges.is_empty() {
        return Ok((content.to_string(), 0));
    }
    let lines: Vec<&str> = content.lines().collect();
    let rows: Vec<String> = ranges
        .iter()
        .flat_map(|r| lines[r.clone()].iter().map(|l| (*l).to_string()))
        .collect();
    let note = projects::ensure_agent_note(dir, name, ver)?;
    let prior = fs::read_to_string(&note)?;
    md::write_atomic(&note, &append_done_rows(&prior, &rows))?;
    let mut drop = vec![false; lines.len()];
    for i in ranges.iter().flat_map(|r| r.clone()) {
        drop[i] = true;
    }
    let kept: Vec<&str> = lines
        .iter()
        .zip(&drop)
        .filter(|(_, d)| !**d)
        .map(|(l, _)| *l)
        .collect();
    Ok((format!("{}\n", kept.join("\n")), ranges.len()))
}

/// Shared body for `done`/`rm`/`start`: apply `f` to the first open wave task matching
/// `query`. Returns `(exit_code, matched_line)`. Non-zero exit on no-match (the cockpit
/// drives these through `execute-silent`, which discards stdout, so a zero exit would hide
/// "matched nothing").
fn edit<F>(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    verb: &str,
    lane: Lane,
    f: F,
) -> Result<(i32, Option<String>)>
where
    F: Fn(&str) -> Option<String>,
{
    let Some((sheet, heading, content)) = sheet_and_wave(p, name, lane)? else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    match md::edit_first_in_section(&content, &heading, |l| pick.hits(l), f) {
        Some((new, matched)) => {
            md::write_atomic(&sheet, &new)?;
            log.info("ptask", &format!("{verb} in {} ({name})", sheet.display()));
            println!("{verb} {}", matched.trim());
            Ok((0, Some(matched)))
        }
        None => {
            eprintln!("no open task matches '{pick}' in {name}");
            Ok((1, None))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A words pick, as `ptask <verb> <query>` builds one.
    fn w(q: &str) -> Pick {
        Pick::new(q, false).unwrap()
    }

    #[test]
    fn an_exact_pick_hits_only_its_own_line_byte_for_byte() {
        let raw = "- [ ] Second task #high";
        let pick = Pick::new(raw, true).unwrap();
        assert!(pick.hits("- [ ] Second task #high"));
        assert!(
            pick.hits("- [ ] Second task #high  "),
            "trailing space is not an edit"
        );
        // Every edit someone else could have made since the UI read the row.
        assert!(!pick.hits("- [ ] second task #high"), "retexted");
        assert!(!pick.hits("- [/] Second task #high"), "started");
        assert!(!pick.hits("- [x] Second task #high"), "ticked");
        assert!(!pick.hits("- [ ] Second task #low"), "reprioritised");
        assert!(
            !pick.hits("- [ ] Second task #high and more"),
            "a longer row"
        );
        // Words still match by contained, case-folded text.
        assert!(w("SECOND").hits("- [ ] Second task #high"));
    }

    #[test]
    fn a_pick_refuses_what_could_match_the_wrong_row() {
        assert!(
            Pick::new("  ", false).is_err(),
            "empty words match every row"
        );
        assert!(
            Pick::new("second task", true).is_err(),
            "exact needs the whole line"
        );
        assert!(
            Pick::new("- [x] done task", true).is_err(),
            "a closed row is never a target"
        );
        assert!(
            Pick::new("- [ ] ", true).is_err(),
            "the placeholder is not a row"
        );
    }

    #[test]
    fn an_exact_pick_refuses_twin_rows() {
        let dir = std::env::temp_dir().join(format!("ptask-twins-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let sheet = dir.join("README.md");
        let row = "- [ ] Same row #high";
        fs::write(
            &sheet,
            format!("## Wave: v0.1.0 (current)\n{row}\n- [ ] other\n"),
        )
        .unwrap();
        let pick = Pick::new(row, true).unwrap();
        assert!(pick.sole_in(&sheet).is_ok(), "one copy is fine");
        // NEGATIVE CONTROL: a second identical line anywhere on the sheet is refused.
        fs::write(
            &sheet,
            format!("## Wave: v0.1.0 (current)\n{row}\n## Wave: v0.2.0\n{row}\n"),
        )
        .unwrap();
        assert!(pick.sole_in(&sheet).is_err());
        // Words picks keep their first-match behaviour.
        assert!(w("same").sole_in(&sheet).is_ok());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_stale_exact_pick_moves_nothing() {
        let h = waves::sections(SRC)[0].heading.clone();
        let stale = Pick::new("- [ ] spawn bug that was renamed since", true).unwrap();
        assert!(move_within(SRC, &stale, &h, "v0.5.0").unwrap().is_none());
        assert!(lift_into(SRC, DEST, &stale, None).unwrap().is_none());
    }

    const SHEET: &str = "\
# demo
Version: v0.1.0

## Wave: new (current)
- [ ] first task
- [x] done task
- [/] doing this
- [ ] second task

## Backlog
- [ ] later
";

    // Negative control for the two-minter bug: before `ensure_task_sheet` routed through
    // `projects::wave_heading`, this appended the literal `## Wave: new (current)` to a
    // sheet declaring `Version: v0.2.0`, and both assertions below failed. A sheet must
    // never name a wave anything other than the version it already declares.
    #[test]
    fn appended_wave_is_named_for_the_sheets_version_not_the_literal_new() {
        let dir = std::env::temp_dir().join(format!("ptask-wave-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let readme = dir.join("README.md");
        // A prose README carrying a version but no wave — the path that used to hardcode.
        fs::write(&readme, "# demo\nVersion: v0.2.0\n\nsome prose\n").unwrap();

        let sheet = ensure_task_sheet(&dir, "demo").unwrap();
        let body = fs::read_to_string(&sheet).unwrap();

        assert_eq!(
            current_wave(&body).as_deref(),
            Some("Wave: v0.2.0 (current)"),
            "the appended wave must carry the sheet's declared version"
        );
        assert!(
            !body.contains("Wave: new"),
            "the literal `new` must never be minted as a wave id: {body}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    // A sheet with no `Version:` line has nothing to inherit, so it opens at v0.0.1 —
    // the same seed `projects --new` uses. Guards the fallback from drifting back to `new`.
    #[test]
    fn a_versionless_fresh_sheet_opens_at_v0_0_1() {
        let dir = std::env::temp_dir().join(format!("ptask-fresh-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let sheet = ensure_task_sheet(&dir, "demo").unwrap();
        let body = fs::read_to_string(&sheet).unwrap();

        assert_eq!(
            current_wave(&body).as_deref(),
            Some("Wave: v0.0.1 (current)")
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn current_wave_finds_the_first_wave_heading() {
        assert_eq!(current_wave(SHEET).as_deref(), Some("Wave: new (current)"));
        assert_eq!(current_wave("# x\n\n## Notes\n- [ ] a\n"), None);
    }

    #[test]
    fn list_positions_cover_only_open_wave_tasks() {
        let h = current_wave(SHEET).unwrap();
        let open: Vec<_> = md::section_numbered(SHEET, &h)
            .into_iter()
            .filter(|(_, l)| md::is_open_task(l))
            .map(|(_, l)| md::task_key(l))
            .collect();
        // the two todos + the in-progress task; NOT the checked one, NOT the backlog item
        assert_eq!(open, vec!["first task", "doing this", "second task"]);
    }

    #[test]
    fn edit_first_ticks_only_the_matching_wave_task() {
        let h = current_wave(SHEET).unwrap();
        let (out, matched) = md::edit_first_in_section(
            SHEET,
            &h,
            |l| is_match(l, "second"),
            |l| Some(md::set_checkbox(l, 'x')),
        )
        .unwrap();
        assert!(matched.contains("second task"));
        assert!(out.contains("- [x] second task"));
        // the backlog task in the next section is untouched
        assert!(out.contains("## Backlog\n- [ ] later"));
    }

    // A sheet with a roadmap: current wave plus two planned ones.
    const ROADMAP: &str = "\
# demo
Version: v1.13.0

## Wave: v1.13.0 (current)
- [ ] live one

## Wave: v1.14.0 (planned)
- [ ] planned one #ai

## Wave: v1.16.0 (planned)
- [ ] much later
";

    // THE invariant the whole roadmap rests on. Everything that predates planned waves -
    // `notes board`, `notes ptask list`, the cockpit - reads the CURRENT wave via
    // this one function. If a planned task ever shows up here, the board starts advertising
    // work that has not started.
    #[test]
    fn the_board_sees_the_current_wave_and_none_of_the_roadmap() {
        let dir = std::env::temp_dir().join(format!("ptask-roadmap-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("README.md"), ROADMAP).unwrap();

        let (ver, open) = open_wave_for_dir(&dir).unwrap();
        assert_eq!(ver, "v1.13.0");
        assert_eq!(
            open,
            vec!["- [ ] live one"],
            "planned work is not on the board"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn current_wave_is_the_first_section_even_with_a_roadmap_below_it() {
        assert_eq!(
            current_wave(ROADMAP).as_deref(),
            Some("Wave: v1.13.0 (current)")
        );
    }

    // `--to` on a version the roadmap does not hold yet opens it, in order, below current.
    #[test]
    fn target_wave_mints_a_planned_section_for_an_unknown_version() {
        let (heading, grown) = target_wave(ROADMAP, Some("v1.15.0"), true).unwrap();
        assert_eq!(heading, "Wave: v1.15.0 (planned)");
        let grown = grown.expect("the sheet had to grow a section");
        let got: Vec<_> = waves::sections(&grown)
            .iter()
            .map(|s| s.version.unwrap())
            .collect();
        assert_eq!(got, vec![(1, 13, 0), (1, 14, 0), (1, 15, 0), (1, 16, 0)]);
    }

    #[test]
    fn target_wave_reuses_a_section_that_already_exists() {
        let (heading, grown) = target_wave(ROADMAP, Some("v1.14.0"), true).unwrap();
        assert_eq!(heading, "Wave: v1.14.0 (planned)");
        assert!(grown.is_none(), "an existing wave must not be re-minted");
    }

    // `move --to` must retag, or the next `sweep` (which buckets by tag) drags the row back.
    #[test]
    fn a_moved_row_takes_its_new_wave_tag_and_survives_a_sweep() {
        let sheet = "# demo\nVersion: v1.13.0\n\n## Wave: v1.13.0 (current)\n- [ ] stays\n\n## Wave: v1.14.0 (planned)\n- [ ] later #v1.14.0\n";
        let line = retag_for(sheet, "- [ ] moved #v1.13.0 #urgent", "v1.14.0");
        assert!(
            line.contains("#v1.14.0") && !line.contains("#v1.13.0"),
            "{line}"
        );
        assert!(
            !line.contains("#urgent"),
            "urgent is only legal in the current wave: {line}"
        );
        let placed = md::insert_under_heading(sheet, "Wave: v1.14.0 (planned)", &[line]);
        let swept = project_sweep::sweep_sheet(&placed).map_or(placed.clone(), |(c, _)| c);
        let later = waves::find(&swept, (1, 14, 0)).unwrap();
        let in_later = swept
            .lines()
            .skip(later.start)
            .take(later.end - later.start)
            .any(|l| l.contains("moved"));
        assert!(in_later, "sweep pulled it back:\n{swept}");
    }

    #[test]
    fn target_wave_rejects_a_non_version() {
        assert!(target_wave(ROADMAP, Some("next"), true).is_err());
        assert!(target_wave(ROADMAP, Some("v1.14"), true).is_err());
    }

    // `move` without a mint (the read-only path) must refuse rather than invent a wave.
    #[test]
    fn target_wave_without_mint_refuses_an_unknown_version() {
        let e = target_wave(ROADMAP, Some("v9.9.9"), false)
            .unwrap_err()
            .to_string();
        assert!(e.contains("no wave v9.9.9"), "{e}");
    }

    // THE proof gate. A bare `done` must be refused - if this ever passes, "closed" and
    // "finished" have come apart again and the roll gate above is counting nothing.
    #[test]
    fn done_without_evidence_is_refused() {
        let e = proof_stamp(None, None).unwrap_err().to_string();
        assert!(e.contains("--proof"), "{e}");
        assert!(e.contains("--unverified"), "{e}");
        // blank is not evidence either
        assert!(proof_stamp(Some("  "), None).is_err());
        assert!(proof_stamp(None, Some("")).is_err());
        // and the two doors are alternatives, not a belt-and-braces
        assert!(proof_stamp(Some("pr:1"), Some("why")).is_err());
    }

    #[test]
    fn both_doors_produce_a_stamp_and_the_unverified_one_says_so() {
        assert_eq!(proof_stamp(Some("pr:1142"), None).unwrap(), "pr:1142");
        assert_eq!(
            proof_stamp(None, Some("no staging seed")).unwrap(),
            "unverified: no staging seed"
        );
    }

    // The stamp joins whatever marker the line already carries rather than opening a
    // second comment - `vk:`/`ask:` readers scan inside the one comment.
    #[test]
    fn the_stamp_merges_into_an_existing_marker() {
        let line = "- [ ] facility save 400 #ai <!-- vk:602 -->";
        let out = md::add_marker(&md::set_checkbox(line, 'x'), "pr:1142");
        assert_eq!(out, "- [x] facility save 400 #ai <!-- vk:602 pr:1142 -->");
        assert_eq!(out.matches("<!--").count(), 1);
    }

    #[test]
    fn the_stamp_opens_a_marker_on_a_bare_line() {
        let out = md::add_marker("- [x] plain task", "unverified: no artifact");
        assert_eq!(out, "- [x] plain task <!-- unverified: no artifact -->");
    }

    // A catch-all sheet and one of the per-project sheets it is being split into.
    const SRC: &str = "\
# unity-playground
Version: v0.4.0

## Wave: v0.4.0 (current)
- [ ] playground thing #high
- [ ] dodgeball spawn bug #v0.4.0 #urgent #game <!-- since:2026-10-01 carried:2 -->
- [ ] dodgeball menu polish #low

## Wave: v0.5.0 (planned)
- [ ] dodgeball netcode #v0.5.0 #high
";

    const DEST: &str = "\
# dodginballs
Version: v1.2.0

## Wave: v1.2.0 (current)
- [ ] existing row #high

## Wave: v1.3.0 (planned)
- [ ] later row #v1.3.0 #high
";

    #[test]
    fn a_cross_project_move_lands_in_the_dest_current_wave_retagged() {
        let m = lift_into(SRC, DEST, &w("spawn bug"), None)
            .unwrap()
            .unwrap();
        assert_eq!(m.from, "Wave: v0.4.0 (current)");
        assert_eq!(m.into, "Wave: v1.2.0 (current)");
        // Source tag swapped for the dest's; priority, other tags and the marker kept.
        assert_eq!(
            m.line,
            "- [ ] dodgeball spawn bug #urgent #game #v1.2.0 <!-- since:2026-10-01 carried:2 -->"
        );
        assert!(
            !m.src.contains("spawn bug"),
            "row must leave SRC:\n{}",
            m.src
        );
        assert!(m.src.contains("- [ ] dodgeball menu polish #low"));
        let cur = waves::find(&m.dest, (1, 2, 0)).unwrap();
        let in_cur: Vec<&str> = m
            .dest
            .lines()
            .skip(cur.start)
            .take(cur.end - cur.start)
            .collect();
        assert!(in_cur.contains(&m.line.as_str()), "{}", m.dest);
        assert!(m.dest.contains("- [ ] existing row #high"));
    }

    #[test]
    fn a_cross_project_move_with_to_lands_in_an_existing_planned_wave() {
        let m = lift_into(SRC, DEST, &w("spawn"), Some("v1.3.0"))
            .unwrap()
            .unwrap();
        assert_eq!(m.into, "Wave: v1.3.0 (planned)");
        // #urgent is only legal in a current wave, the same rule the same-sheet move applies.
        assert_eq!(
            m.line,
            "- [ ] dodgeball spawn bug #game #high #v1.3.0 <!-- since:2026-10-01 carried:2 -->"
        );
        let later = waves::find(&m.dest, (1, 3, 0)).unwrap();
        assert!(m
            .dest
            .lines()
            .skip(later.start)
            .take(later.end - later.start)
            .any(|l| l == m.line));
    }

    // The source search spans every wave, as the same-sheet move's does.
    #[test]
    fn a_cross_project_move_finds_a_row_in_a_planned_source_wave() {
        let m = lift_into(SRC, DEST, &w("netcode"), None).unwrap().unwrap();
        assert_eq!(m.from, "Wave: v0.5.0 (planned)");
        assert_eq!(m.line, "- [ ] dodgeball netcode #high #v1.2.0");
    }

    // Agents may not create planned waves on another project's roadmap.
    #[test]
    fn a_cross_project_move_refuses_a_dest_wave_that_does_not_exist() {
        let e = lift_into(SRC, DEST, &w("spawn"), Some("v9.0.0"))
            .unwrap_err()
            .to_string();
        assert!(e.contains("no wave v9.0.0"), "{e}");
    }

    #[test]
    fn a_cross_project_move_refuses_a_dest_with_no_wave() {
        assert!(lift_into(SRC, "# prose only\n\nnothing here\n", &w("spawn"), None).is_err());
    }

    #[test]
    fn a_cross_project_move_with_no_match_is_none() {
        assert!(lift_into(SRC, DEST, &w("no such row"), None)
            .unwrap()
            .is_none());
        // A closed row is not movable.
        let closed = SRC.replace("- [ ] dodgeball menu", "- [x] dodgeball menu");
        assert!(lift_into(&closed, DEST, &w("menu polish"), None)
            .unwrap()
            .is_none());
    }

    // A dest wave with no parseable version gets no tag, never the source's stale one.
    #[test]
    fn a_cross_project_move_into_an_unversioned_wave_drops_the_source_tag() {
        let dest = "# legacy\n\n## Wave: new (current)\n- [ ] x\n";
        let m = lift_into(SRC, dest, &w("spawn"), None).unwrap().unwrap();
        assert!(!m.line.contains("#v0.4.0"), "{}", m.line);
        assert!(m.line.contains("<!-- since:2026-10-01 carried:2 -->"));
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ptask-xproj-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn transfer_writes_both_sheets() {
        let d = scratch("ok");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let m = transfer(&s, &t, &w("spawn"), None).unwrap().unwrap();
        assert_eq!(fs::read_to_string(&s).unwrap(), m.src);
        assert_eq!(fs::read_to_string(&t).unwrap(), m.dest);
        assert!(!m.src.contains("spawn") && m.dest.contains("spawn"));
        let _ = fs::remove_dir_all(&d);
    }

    // Every refusal must leave both sheets byte-identical.
    #[test]
    fn transfer_refusals_write_nothing() {
        let d = scratch("refuse");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let same = transfer(&s, &s, &w("spawn"), None).unwrap_err().to_string();
        assert!(same.contains("same sheet"), "{same}");
        assert!(transfer(&s, &t, &w("spawn"), Some("v9.0.0")).is_err());
        assert!(transfer(&s, &t, &w("no such row"), None).unwrap().is_none());
        assert_eq!(fs::read_to_string(&s).unwrap(), SRC);
        assert_eq!(fs::read_to_string(&t).unwrap(), DEST);
        let _ = fs::remove_dir_all(&d);
    }

    // The same-sheet move, pinned through its refactor into `move_within`: same row, same
    // retag, same placement, and a move onto the row's own wave still matches nothing.
    #[test]
    fn the_same_project_move_is_unchanged() {
        let (h, grown) = target_wave(SRC, Some("v0.5.0"), true).unwrap();
        assert!(grown.is_none());
        let (new, line, from) = move_within(SRC, &w("spawn"), &h, "v0.5.0")
            .unwrap()
            .unwrap();
        assert_eq!(from, "Wave: v0.4.0 (current)");
        assert_eq!(
            line,
            "- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->"
        );
        assert_eq!(
            new,
            "# unity-playground\nVersion: v0.4.0\n\n## Wave: v0.4.0 (current)\n- [ ] playground thing #high\n- [ ] dodgeball menu polish #low\n\n## Wave: v0.5.0 (planned)\n- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->\n- [ ] dodgeball netcode #v0.5.0 #high\n"
        );
        assert!(move_within(SRC, &w("netcode"), &h, "v0.5.0")
            .unwrap()
            .is_none());
    }

    #[test]
    fn start_toggles_todo_and_in_progress() {
        let h = current_wave(SHEET).unwrap();
        let (out, _) = md::edit_first_in_section(
            SHEET,
            &h,
            |l| is_match(l, "first"),
            |l| Some(toggle_started(l, None)),
        )
        .unwrap();
        assert!(out.contains("- [/] first task"));
    }

    // The join between a queue item and its row: the first start gives the row its id, and
    // neither a second start nor a row that already has one mints another.
    #[test]
    fn a_row_going_to_started_gets_its_id_once() {
        let line = toggle_started("- [ ] fix(a): thing #high", Some("ar-7"));
        assert_eq!(line, "- [/] fix(a): thing #high <!-- id:ar-7 -->");
        let back = toggle_started(&line, Some("ar-8"));
        assert_eq!(back, "- [ ] fix(a): thing #high <!-- id:ar-7 -->");
        assert_eq!(
            toggle_started(&back, Some("ar-8")),
            "- [/] fix(a): thing #high <!-- id:ar-7 -->"
        );
        assert_eq!(
            toggle_started("- [ ] a <!-- carried:1 -->", Some("ar-9")),
            "- [/] a <!-- carried:1 id:ar-9 -->"
        );
        // No code, no id: the row still starts, and the caller decides what that means.
        assert_eq!(toggle_started("- [ ] a", None), "- [/] a");
    }

    const BOARD: &str = "\
# demo - agent board
Version: v0.0.1

## Wave: v0.0.1 (current)
- [ ] open row #high
- [x] shipped row #high <!-- pr:12 -->
  - with a note under it
- [ ] open parent
  - [x] a done subtask stays with its parent
- [x] second shipped row
";

    #[test]
    fn done_rows_are_top_level_checked_rows_with_their_children() {
        let lines: Vec<&str> = BOARD.lines().collect();
        let rows: Vec<Vec<&str>> = done_rows(BOARD)
            .into_iter()
            .map(|r| lines[r].to_vec())
            .collect();
        assert_eq!(
            rows,
            vec![
                vec![
                    "- [x] shipped row #high <!-- pr:12 -->",
                    "  - with a note under it"
                ],
                vec!["- [x] second shipped row"],
            ]
        );
    }

    #[test]
    fn done_rows_join_the_end_of_their_section() {
        let note = "# n\n\n## Notes\n";
        let once = append_done_rows(note, &["- [x] one".to_string()]);
        assert!(
            once.ends_with("## Notes\n\n## Done rows\n- [x] one\n"),
            "{once}"
        );
        let twice = append_done_rows(&once, &["- [x] two".to_string()]);
        assert!(
            twice.ends_with("## Done rows\n- [x] one\n- [x] two\n"),
            "{twice}"
        );
    }

    #[test]
    fn archive_moves_done_rows_to_the_versions_note_the_proof_is_in() {
        let root = std::env::temp_dir().join(format!("ptask-archive-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut p = crate::config::test_profile(&root.to_string_lossy());
        let projects = root.join("lab/projects/current");
        let dir = projects.join("demo");
        fs::create_dir_all(dir.join("agent")).unwrap();
        let index = root.join("lab/projects/index.md");
        fs::write(
            &index,
            "## Current\n- [[lab/projects/current/demo/summary|demo]]\n",
        )
        .unwrap();
        fs::write(dir.join("summary.md"), "# demo\n").unwrap();
        fs::write(
            dir.join("README.md"),
            "# demo\nVersion: v0.3.0 #beta\n\n## Wave: v0.3.0 (current)\n- [ ] human row\n",
        )
        .unwrap();
        fs::write(dir.join("agent/README.md"), BOARD).unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);

        assert!(archive(&p, &log, "demo", false, Lane::Human).is_err());
        archive(&p, &log, "demo", true, Lane::Agent).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("agent/README.md")).unwrap(),
            BOARD
        );

        archive(&p, &log, "demo", false, Lane::Agent).unwrap();
        let board = fs::read_to_string(dir.join("agent/README.md")).unwrap();
        assert_eq!(
            board,
            "# demo - agent board\nVersion: v0.0.1\n\n## Wave: v0.0.1 (current)\n- [ ] open row #high\n- [ ] open parent\n  - [x] a done subtask stays with its parent\n"
        );
        let note = fs::read_to_string(dir.join("agent/versions/v0.3.0.md")).unwrap();
        assert!(
            note.ends_with("## Done rows\n- [x] shipped row #high <!-- pr:12 -->\n  - with a note under it\n- [x] second shipped row\n"),
            "{note}"
        );
        // nothing left to move is not an error
        assert_eq!(archive(&p, &log, "demo", false, Lane::Agent).unwrap(), 0);
        let _ = fs::remove_dir_all(&root);
    }

    // An id is never reused: the max is taken over both lanes and the archive, and a dropped
    // row keeps its id on the sheet.
    #[test]
    fn next_id_is_one_past_the_highest_id_anywhere_in_the_project() {
        let dir = std::env::temp_dir().join(format!("ptask-ids-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("agent")).unwrap();
        fs::create_dir_all(dir.join("versions")).unwrap();
        assert_eq!(next_id(&dir, "ar"), "ar-1", "an empty project starts at 1");
        fs::write(dir.join("README.md"), "- [ ] a <!-- id:ar-3 -->\n").unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "- [x] b <!-- id:ar-9 dropped: stale -->\n",
        )
        .unwrap();
        fs::write(
            dir.join("versions/v0.1.0.md"),
            "- [x] c <!-- id:ar-12 pr:4 -->\n",
        )
        .unwrap();
        fs::write(dir.join("notes.txt"), "id:ar-99 is not on a sheet\n").unwrap();
        fs::write(
            dir.join("other.md"),
            "- [ ] d <!-- id:bar-40 id:xar-41 -->\n",
        )
        .unwrap();
        assert_eq!(next_id(&dir, "ar"), "ar-13");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_drop_says_why_or_names_its_duplicate_never_both() {
        assert_eq!(drop_stamp(Some("stale"), None).unwrap(), "dropped: stale");
        assert_eq!(drop_stamp(None, Some("ar-142")).unwrap(), "dup:ar-142");
        assert!(drop_stamp(None, None).is_err(), "a drop with no reason");
        assert!(drop_stamp(Some("x"), Some("ar-1")).is_err(), "both");
        assert!(
            drop_stamp(None, Some("the other one")).is_err(),
            "--dup takes an id"
        );
        assert!(
            drop_stamp(Some("  "), None).is_err(),
            "a blank reason is no reason"
        );
    }

    #[test]
    fn an_id_shaped_query_picks_that_row_and_no_other() {
        let pick = w("AR-14");
        assert!(matches!(pick, Pick::Id(ref id) if id == "ar-14"));
        assert!(pick.hits("- [ ] fix(a): b #high <!-- id:ar-14 -->"));
        assert!(pick.hits("- [/] fix(a): b #high <!-- id:ar-14 pr:3 -->"));
        assert!(
            !pick.hits("- [ ] fix(a): b #high <!-- id:ar-142 -->"),
            "a prefix"
        );
        assert!(
            !pick.hits("- [x] fix(a): b #high <!-- id:ar-14 -->"),
            "closed"
        );
        assert!(
            !pick.hits("- [ ] see ar-14 for the cause #high"),
            "text is not an id"
        );
        assert!(matches!(w("inotify"), Pick::Words(_)));
    }
}
