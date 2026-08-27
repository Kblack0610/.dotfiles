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
    let sheet = task_sheet(dir)?;
    let content = fs::read_to_string(&sheet).ok()?;
    let heading = current_wave(&content)?;
    let open: Vec<String> = md::section_numbered(&content, &heading)
        .into_iter()
        .filter(|(_, l)| md::is_open_task(l))
        .map(|(_, l)| l.trim_end().to_string())
        .collect();
    Some((projects::wave_version_of(&content), open))
}

/// The sheet + its resolved current-wave heading, for a named project. `None` when the
/// project has no task sheet yet (a read verb then lists nothing).
fn sheet_and_wave(p: &Profile, name: &str) -> Result<Option<(PathBuf, String, String)>> {
    let dir = projects::project_dir(p, name)?;
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
fn is_match(line: &str, query: &str) -> bool {
    md::is_open_task(line) && md::task_key(line).contains(query)
}

/// `notes ptask <name> list [--wave vX.Y.Z | --all]` — TSV of OPEN tasks.
///
/// Bare `list` is the current wave and emits exactly the four columns it always has —
/// `path<TAB>line<TAB>key<TAB>text` — because the cockpit and `/wave` both parse it. A
/// wave SELECTOR adds a fifth column (the wave's version) rather than changing the first
/// four, so a reader that only wants `$1..$4` is unaffected either way.
pub fn list(p: &Profile, name: &str, wave: Option<&str>, all: bool) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
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
/// Unlike daily `focus add`, wave tasks are NOT day-stamped (they live in the version's
/// wave until done or rolled, not carried forward).
pub fn add(p: &Profile, log: &Logger, name: &str, text: &str, to: Option<&str>) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text)");
    }
    let dir = projects::project_dir(p, name)?;
    let sheet = ensure_task_sheet(&dir, name)?;
    let content = fs::read_to_string(&sheet)?;
    let (heading, grown) = target_wave(&content, to, true)?;
    let base = grown.unwrap_or(content);
    let line = format!("- [ ] {text}");
    let new = md::insert_under_heading(&base, &heading, std::slice::from_ref(&line));
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("added to {} ({name})", sheet.display()));
    println!("{line}");
    if to.is_some() {
        println!("  -> {heading}");
    }
    Ok(0)
}

/// `notes ptask <name> move <query> --to vX.Y.Z` — move the first open task matching
/// `<query>` from whatever wave holds it into `<ver>`, minting that wave if it is new.
///
/// The verb that splits a pile into a roadmap, and the one the roll gate points at: a
/// version that still has open work does not close, so either finish the task or say
/// explicitly which version it belongs to instead.
pub fn move_task(p: &Profile, log: &Logger, name: &str, query: &str, to: &str) -> Result<i32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let dir = projects::project_dir(p, name)?;
    let Some(sheet) = task_sheet(&dir) else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    let content = fs::read_to_string(&sheet)?;
    let (heading, grown) = target_wave(&content, Some(to), true)?;
    let content = grown.unwrap_or(content);

    // Find it in any wave EXCEPT the target, so a move onto its own wave is a clear no-op
    // rather than a silent delete-and-reinsert.
    let mut found: Option<(String, String)> = None; // (source heading, line)
    for s in waves::sections(&content) {
        if s.heading == heading {
            continue;
        }
        if let Some((_, l)) = md::section_numbered(&content, &s.heading)
            .into_iter()
            .find(|(_, l)| is_match(l, &query))
        {
            found = Some((s.heading.clone(), l.trim_end().to_string()));
            break;
        }
    }
    let Some((from, line)) = found else {
        eprintln!("no open task matches '{query}' outside {heading} in {name}");
        return Ok(1);
    };
    let Some((cut, _)) = md::edit_first_in_section(&content, &from, |l| is_match(l, &query), |_| None)
    else {
        bail!("could not lift '{query}' out of {from}");
    };
    let new = md::insert_under_heading(&cut, &heading, std::slice::from_ref(&line));
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("moved to {heading} in {} ({name})", sheet.display()));
    println!("moved {}\n  {from} -> {heading}", line.trim());
    Ok(0)
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
pub fn step(p: &Profile, log: &Logger, name: &str, query: &str, dir: i32) -> Result<i32> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let dir_word = if dir < 0 { "promote" } else { "demote" };
    let dir_proj = projects::project_dir(p, name)?;
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
            .find(|(_, l)| is_match(l, &q))
        {
            let tagged = md::wave_tag(l).and_then(|t| waves::parse(t.trim_start_matches('#')));
            at = Some((tagged.unwrap_or(sv), s.heading.clone(), l.trim_end().to_string()));
            break;
        }
    }
    let Some((at_v, from, line)) = at else {
        eprintln!("no open task matches '{query}' in {name}");
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
    let Some((cut, _)) =
        md::edit_first_in_section(&content, &from, |l| is_match(l, &q), |_| None)
    else {
        bail!("could not lift '{query}' out of {from}");
    };
    let new = md::insert_under_heading(&cut, &heading, std::slice::from_ref(&retagged));
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("{dir_word}d to {heading} in {} ({name})", sheet.display()));
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
///   leaving it blank until it means nothing. `/wave`'s report already had this instinct:
///   `n/a - <why>` mandatory rather than blank.
///
/// Either way the row lands in the version's AI note (`ai/<vX.Y.Z>.md`), which is what
/// turns a pile of ticked boxes into an evidence trail somebody can audit.
pub fn done(
    p: &Profile,
    log: &Logger,
    name: &str,
    query: &str,
    proof: Option<&str>,
    unverified: Option<&str>,
) -> Result<i32> {
    let stamp = proof_stamp(proof, unverified)?;
    let marker = stamp.clone();
    let (code, matched) = edit(p, log, name, query, "done", move |l| {
        Some(md::add_marker(&md::set_checkbox(l, 'x'), &marker))
    })?;
    let Some(matched) = matched.filter(|_| code == 0) else {
        return Ok(code);
    };
    // The task as the SHEET has it, not as the query spelled it — the row has to be
    // recognisable next to the checkbox it vouches for.
    record_proof(p, name, &md::task_key(&matched), &stamp)?;
    Ok(0)
}

/// The marker text a `done` will stamp, or the error explaining that it needs one.
///
/// The gate itself, kept out of `done` so it is testable without a vault. A bare `done`
/// must FAIL: the roll gate above only means something if a ticked checkbox does.
fn proof_stamp(proof: Option<&str>, unverified: Option<&str>) -> Result<String> {
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

/// Append the proof row for the task just closed to the current version's AI note.
///
/// Best-effort by design: the checkbox is already written by the time this runs, and a
/// vault that cannot take the note must not make `done` look like it failed. It says so
/// on stderr instead.
fn record_proof(p: &Profile, name: &str, query: &str, stamp: &str) -> Result<()> {
    let Ok(dir) = projects::project_dir(p, name) else {
        return Ok(());
    };
    let Some(sheet) = task_sheet(&dir) else {
        return Ok(());
    };
    let Ok(content) = fs::read_to_string(&sheet) else {
        return Ok(());
    };
    let ver = projects::wave_version_of(&content);
    let when = chrono::Local::now().format("%Y-%m-%d").to_string();
    match projects::append_proof(&dir, name, &ver, query.trim(), stamp, &when) {
        Ok(path) => println!("  proof -> {}", path.display()),
        Err(e) => eprintln!("(proof row not written: {e})"),
    }
    Ok(())
}

/// `notes ptask <name> rm <query>` — delete the first open wave task matching `<query>`.
pub fn rm(p: &Profile, log: &Logger, name: &str, query: &str) -> Result<i32> {
    Ok(edit(p, log, name, query, "removed", |_| None)?.0)
}

/// `notes ptask <name> start <query>` — toggle the first matching wave task between todo
/// (`[ ]`) and in-progress (`[/]`).
pub fn start(p: &Profile, log: &Logger, name: &str, query: &str) -> Result<i32> {
    Ok(edit(p, log, name, query, "toggled", |l| {
        let mark = if l.trim_start().starts_with("- [/]") {
            ' '
        } else {
            '/'
        };
        Some(md::set_checkbox(l, mark))
    })?
    .0)
}

/// `notes ptask <name> sweep [--dry-run]` - reorganize the sheet's wave roadmap.
///
/// Logs under `ptask:` like every other verb here, because the Stop gate greps the notes log
/// for `(focus|ptask):` to decide a turn made progress; a verb logged under anything else is
/// invisible to it and the session gets blocked for work it did.
pub fn sweep(p: &Profile, log: &Logger, name: &str, dry_run: bool) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
    let Some(sheet) = task_sheet(&dir) else {
        bail!("{name} has no task sheet with a `## Wave` section");
    };
    let content = fs::read_to_string(&sheet)?;
    let Some((new, report)) = project_sweep::sweep_sheet(&content) else {
        println!("{}: already swept (or no `Version:` / an unversioned wave heading)", name);
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

/// Shared body for `done`/`rm`/`start`: apply `f` to the first open wave task matching
/// `query`. Returns `(exit_code, matched_line)`. Non-zero exit on no-match (the cockpit
/// drives these through `execute-silent`, which discards stdout, so a zero exit would hide
/// "matched nothing").
fn edit<F>(
    p: &Profile,
    log: &Logger,
    name: &str,
    query: &str,
    verb: &str,
    f: F,
) -> Result<(i32, Option<String>)>
where
    F: Fn(&str) -> Option<String>,
{
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let Some((sheet, heading, content)) = sheet_and_wave(p, name)? else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    match md::edit_first_in_section(&content, &heading, |l| is_match(l, &query), f) {
        Some((new, matched)) => {
            md::write_atomic(&sheet, &new)?;
            log.info("ptask", &format!("{verb} in {} ({name})", sheet.display()));
            println!("{verb} {}", matched.trim());
            Ok((0, Some(matched)))
        }
        None => {
            eprintln!("no open task matches '{query}' in {name}");
            Ok((1, None))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

        assert_eq!(current_wave(&body).as_deref(), Some("Wave: v0.0.1 (current)"));
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
        let (out, matched) =
            md::edit_first_in_section(SHEET, &h, |l| is_match(l, "second"), |l| {
                Some(md::set_checkbox(l, 'x'))
            })
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
    // `notes board`, `notes ptask list`, `/wave`, the cockpit - reads the CURRENT wave via
    // this one function. If a planned task ever shows up here, the board starts advertising
    // work that has not started and `/wave` starts dispatching it.
    #[test]
    fn the_board_sees_the_current_wave_and_none_of_the_roadmap() {
        let dir = std::env::temp_dir().join(format!("ptask-roadmap-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("README.md"), ROADMAP).unwrap();

        let (ver, open) = open_wave_for_dir(&dir).unwrap();
        assert_eq!(ver, "v1.13.0");
        assert_eq!(open, vec!["- [ ] live one"], "planned work is not on the board");
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

    #[test]
    fn target_wave_rejects_a_non_version() {
        assert!(target_wave(ROADMAP, Some("next"), true).is_err());
        assert!(target_wave(ROADMAP, Some("v1.14"), true).is_err());
    }

    // `move` without a mint (the read-only path) must refuse rather than invent a wave.
    #[test]
    fn target_wave_without_mint_refuses_an_unknown_version() {
        let e = target_wave(ROADMAP, Some("v9.9.9"), false).unwrap_err().to_string();
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

    #[test]
    fn start_toggles_todo_and_in_progress() {
        let h = current_wave(SHEET).unwrap();
        let toggle = |l: &str| -> Option<String> {
            let mark = if l.trim_start().starts_with("- [/]") {
                ' '
            } else {
                '/'
            };
            Some(md::set_checkbox(l, mark))
        };
        let (out, _) =
            md::edit_first_in_section(SHEET, &h, |l| is_match(l, "first"), toggle).unwrap();
        assert!(out.contains("- [/] first task"));
    }
}
