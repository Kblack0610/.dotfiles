//! `notes focus sweep` — reorganize today's `## Focus` by priority + status, so a task
//! moves between lanes as its `#urgent`/`#high`/`#low` tag is set or its
//! checkbox is checked: untagged todos on top, then `### Urgent` / `### High` /
//! `### Low` (open tasks, in-priority order), done (`[x]`) under
//! `--- / ### Done`. An in-progress `[/]` task keeps its mark inside its priority lane.
//! Once active, empty lane headers + Done persist as drop targets, and an untagged task
//! dropped under a lane header inherits that lane's tag.
//!
//! This mirrors the nvim buffer sweep (markdown.lua rebuild_focus_body) so that
//! tagging/checking a task from the cockpit organizes the note exactly like cycling it in
//! the editor does — the note stays grouped no matter which surface you touch. Only the
//! AUTHORED region is reorganized: a rollup mirror (everything from md::ROLLUP_START on)
//! is left untouched at the end of the section.
//!
//! Before the lanes are rebuilt, an open row tagged `#idea` leaves Focus for the ideas file it
//! names: `#idea:<project>` goes to that project's `ideas.md`, a bare `#idea` to the
//! cross-project file (`ideas` in the config, default `lab/ideas/_IDEAS.md`). An idea is not
//! today's work, so it does not belong on today's list. The nvim buffer sweep does not do
//! this move; the next `notes focus sweep` does.
//!
//! Lives in its own module to stay clear of a concurrent focus.rs refactor.

use crate::config::Profile;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use crate::sweep;
use anyhow::{bail, Result};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

// The priority lanes are md::PRIORITIES (the single source of truth, most-urgent first),
// shared with tag detection. Untagged open tasks (rank == PRIORITIES.len()) stay unheaded on
// top; checked tasks go under ### Done; each open task otherwise buckets by its tag. The
// nvim sweep (markdown.lua LANES) mirrors the same set.

/// Pure core: reorganize the ## Focus section of `content` by status. `None` when the
/// section is absent or already organized (no change).
///
/// The lane model itself lives in `sweep`, shared with the project-sheet sweep. Focus
/// offers all three lanes.
fn sweep_content(content: &str) -> Option<String> {
    sweep::sweep_section(content, |h| h.eq_ignore_ascii_case("Focus"))
}

/// notes focus start <query> — toggle the first matching authored `## Focus` task
/// between [ ] (todo) and `[/]` (in progress). Pair with a sweep to move it into the
/// right lane. Only the authored region is scanned (stops at the next H2 / rollup
/// sentinel), matching by the same normalised key as done.
pub fn start(p: &Profile, log: &Logger, query: &str) -> Result<i32> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        bail!("which one? (provide a word from the task)");
    }
    let note = daily::today_path(p);
    if !note.exists() {
        bail!("no daily note yet — run: notes today");
    }
    let content = fs::read_to_string(&note)?;
    let mut out: Vec<String> = Vec::new();
    let mut in_focus = false;
    let mut toggled = false;
    for line in content.lines() {
        if !toggled {
            if let Some(rest) = line.strip_prefix("## ") {
                in_focus = rest.trim().eq_ignore_ascii_case("Focus");
            } else if in_focus && line.trim() == md::ROLLUP_START {
                in_focus = false;
            } else if in_focus
                && md::is_task(line)
                && !md::is_checked(line)
                && !md::is_empty_unchecked(line)
                && md::task_key(line).contains(&q)
            {
                let flipped = if line.trim_start().starts_with("- [/]") {
                    line.replacen("- [/]", "- [ ]", 1)
                } else {
                    line.replacen("- [ ]", "- [/]", 1)
                };
                out.push(flipped);
                toggled = true;
                continue;
            }
        }
        out.push(line.to_string());
    }
    if !toggled {
        bail!("no open focus item matches '{query}'");
    }
    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    fs::write(&note, joined)?;
    log.info("focus", "toggled in-progress");
    Ok(0)
}

/// Pull every open `#idea` row out of the authored `## Focus` region, with the indented
/// lines under it. `route` names each row's ideas file from its tag (`None` = no project,
/// `Some(name)` = `#idea:<name>`); a row it returns `None` for stays where it is.
///
/// Returns the note without the moved rows and each file's rows in note order, or `None`
/// when nothing moves.
fn take_ideas(
    content: &str,
    route: impl FnMut(Option<&str>) -> Option<PathBuf>,
) -> Option<(String, BTreeMap<PathBuf, Vec<String>>)> {
    take_tagged(content, md::idea_tag, route)
}

/// [`take_ideas`] for any routing tag: `tag_of` reads a row's tag (`None` = not tagged).
fn take_tagged(
    content: &str,
    tag_of: impl Fn(&str) -> Option<Option<String>>,
    mut route: impl FnMut(Option<&str>) -> Option<PathBuf>,
) -> Option<(String, BTreeMap<PathBuf, Vec<String>>)> {
    let lines: Vec<&str> = content.lines().collect();
    let span = md::section_span(&lines, "Focus")?;
    let mut moved: BTreeMap<PathBuf, Vec<String>> = BTreeMap::new();
    let mut keep: Vec<&str> = Vec::with_capacity(lines.len());
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let tag = (span.contains(&i) && md::is_open_task(line))
            .then(|| tag_of(line))
            .flatten();
        let Some(target) = tag.and_then(|t| route(t.as_deref())) else {
            keep.push(line);
            i += 1;
            continue;
        };
        let indent = line.len() - line.trim_start().len();
        let mut end = i + 1;
        while end < span.end
            && !lines[end].trim().is_empty()
            && lines[end].len() - lines[end].trim_start().len() > indent
        {
            end += 1;
        }
        let rows = moved.entry(target).or_default();
        rows.extend(lines[i..end].iter().map(|l| l.to_string()));
        i = end;
    }
    if moved.is_empty() {
        return None;
    }
    let mut out = keep.join("\n");
    if content.ends_with('\n') {
        out.push('\n');
    }
    Some((out, moved))
}

/// Append `rows` to the ideas file at `path`, creating it with `header` when absent. A row
/// already in the file is not written twice, so a sweep that stopped between this write and
/// the note's can run again.
fn append_ideas(path: &Path, header: &str, rows: &[String]) -> Result<()> {
    let existing = fs::read_to_string(path).unwrap_or_else(|_| header.to_string());
    let have: Vec<&str> = existing.lines().collect();
    let new: Vec<&String> = rows
        .iter()
        .filter(|r| !have.contains(&r.as_str()))
        .collect();
    if new.is_empty() {
        return Ok(());
    }
    let mut out = existing.trim_end().to_string();
    out.push('\n');
    for r in new {
        out.push('\n');
        out.push_str(r);
    }
    out.push('\n');
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    md::write_atomic(path, &out)
}

/// Move today's `#idea` rows to their ideas files ([`take_ideas`]), resolving a project by
/// `project_dir`. The files are written before the note, so a failure part way leaves a row
/// in both places, never in neither.
fn move_ideas(
    p: &Profile,
    log: &Logger,
    content: &str,
    project_dir: impl Fn(&str) -> Option<PathBuf>,
) -> Result<Option<String>> {
    let mut headers: BTreeMap<PathBuf, String> = BTreeMap::new();
    let taken = take_ideas(content, |proj| {
        let (path, header) = match proj {
            None => (p.ideas.clone(), "# Ideas\n".to_string()),
            Some(name) => match project_dir(name) {
                Some(dir) => (dir.join("ideas.md"), crate::projects::ideas_template(name)),
                None => {
                    eprintln!("focus sweep: #idea:{name} names no project; the row stays in Focus");
                    return None;
                }
            },
        };
        headers.insert(path.clone(), header);
        Some(path)
    });
    let Some((rest, moved)) = taken else {
        return Ok(None);
    };
    for (path, rows) in &moved {
        append_ideas(path, &headers[path], rows)?;
        let n = rows.iter().filter(|r| md::is_task(r)).count();
        log.info(
            "focus",
            &format!("moved {n} #idea row(s) to {}", path.display()),
        );
        println!("moved {n} idea(s) -> {}", path.display());
    }
    Ok(Some(rest))
}

/// Move today's `#p:<project>` rows, with their indented lines, to the `## Inbox` of that
/// project's sheet, the tag taken off and the rest as typed, for the triager to file. Like
/// [`move_ideas`] the sheets are written before the note, and a row already in an inbox is
/// not written twice. A name that is no project leaves the row in Focus.
fn move_to_inboxes(
    p: &Profile,
    log: &Logger,
    content: &str,
    project_dir: impl Fn(&str) -> Option<PathBuf>,
) -> Result<Option<String>> {
    let taken = take_tagged(
        content,
        |l| md::project_tag(l).map(Some),
        |proj| {
            let name = proj?;
            let dir = project_dir(name);
            if dir.is_none() {
                eprintln!("focus sweep: #p:{name} names no project; the row stays in Focus");
            }
            dir
        },
    );
    let Some((rest, moved)) = taken else {
        return Ok(None);
    };
    for (dir, rows) in &moved {
        // The group's first line is the tagged row itself.
        let name = rows
            .first()
            .and_then(|r| md::project_tag(r))
            .unwrap_or_default();
        let lines: Vec<String> = rows.iter().map(|r| md::without_project_tag(r)).collect();
        let path = crate::project_tasks::inbox_put(p, dir, &name, &lines)?;
        log.info(
            "focus",
            &format!(
                "moved {} #p row(s) to {}'s inbox",
                lines.len(),
                path.display()
            ),
        );
        println!(
            "moved {} row(s) -> {name} inbox",
            lines.iter().filter(|r| md::is_task(r)).count()
        );
    }
    Ok(Some(rest))
}

/// notes focus sweep: move `#idea` rows to their ideas files and `#p:<project>` rows to
/// their project's inbox, then organize today's
/// `## Focus` by status in place.
pub fn sweep(p: &Profile, log: &Logger) -> Result<i32> {
    let note = daily::today_path(p);
    if !note.exists() {
        return Ok(0);
    }
    let content = fs::read_to_string(&note)?;
    let dir_of = |name: &str| crate::projects::project_dir(p, name).ok();
    let moved = move_ideas(p, log, &content, dir_of)?;
    let moved = move_to_inboxes(p, log, moved.as_deref().unwrap_or(&content), dir_of)?.or(moved);
    let base = moved.as_deref().unwrap_or(&content);
    match sweep_content(base) {
        Some(new) => {
            fs::write(&note, new)?;
            log.info("focus", "swept ## Focus by status");
        }
        None if moved.is_some() => fs::write(&note, base)?,
        None => {}
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_open_tasks_by_priority() {
        let note = "\
## Focus
- [ ] untagged one
- [ ] top task #high
- [x] finished it
- [ ] fire #urgent
- [ ] someday #low
- [ ]

## Notes
after
";
        let out = sweep_content(note).unwrap();
        let focus = out.split("## Notes").next().unwrap();
        // lanes descend urgent -> high -> low; done at the foot
        let urgent = focus.find("### Urgent").unwrap();
        let high = focus.find("### High").unwrap();
        let low = focus.find("### Low").unwrap();
        let done = focus.find("### Done").unwrap();
        // an untagged task takes the default and lands in High, not above the lanes
        let untagged = focus.find("untagged one").unwrap();
        assert!(
            out.contains("- [ ] untagged one #high"),
            "defaulted:\n{out}"
        );
        assert!(
            untagged > high && untagged < low,
            "in the High lane:\n{out}"
        );
        assert!(
            urgent < high && high < low,
            "lanes ordered urgent > high > low"
        );
        assert!(focus.find("fire").unwrap() > urgent && focus.find("fire").unwrap() < high);
        assert!(low < done, "Done is last");
        assert!(
            focus.find("finished it").unwrap() > done,
            "checked task under Done"
        );
        assert!(out.contains("## Notes\nafter"), "later sections untouched");
    }

    #[test]
    fn checked_go_to_done_regardless_of_tag() {
        // a checked task with a priority tag lands under Done, not its priority lane
        let note = "## Focus\n- [x] shipped it #high\n- [ ] open #high\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        let done = out.find("### Done").unwrap();
        assert!(
            out.find("shipped it").unwrap() > done,
            "checked+tagged under Done"
        );
        assert!(
            out.find("open").unwrap() < done,
            "open task stays in its High lane"
        );
    }

    #[test]
    fn inprogress_keeps_its_mark_in_its_lane() {
        let note = "## Focus\n- [/] doing #urgent\n- [ ] x\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        assert!(out.contains("### Urgent"));
        // the in-progress mark survives, under its priority lane (no separate In progress)
        assert!(out.contains("- [/] doing #urgent"));
        assert!(!out.contains("### In progress"));
    }

    #[test]
    fn leaves_the_rollup_block_in_place() {
        let note = format!(
            "## Focus\n- [x] mine done\n- [ ] mine open\n\n{}\n### somejob\n- [ ] theirs\n",
            md::ROLLUP_START
        );
        let out = sweep_content(&note).unwrap();
        // the mirrored (post-sentinel) task is never pulled into a lane
        let before_sentinel = out.split(md::ROLLUP_START).next().unwrap();
        assert!(before_sentinel.contains("### Done"));
        assert!(before_sentinel.contains("mine done"));
        assert!(!before_sentinel.contains("theirs"));
        assert!(out.contains(&format!("{}\n### somejob\n- [ ] theirs", md::ROLLUP_START)));
    }

    // A note holding nothing but the placeholder still sweeps to nothing, so a fresh daily
    // note is not born full of empty lane headers. The placeholder is the one task line that
    // never takes the default - it is scaffold the sweep re-emits, and tagging it would make
    // every sweep differ from the one before it.
    #[test]
    fn a_note_with_only_the_placeholder_is_left_alone() {
        let note = "## Focus\n- [ ] \n\n## Notes\n";
        assert!(sweep_content(note).is_none(), "nothing to organize");
    }

    // But a real untagged task IS something to organize now: it takes the default and the
    // lanes appear around it.
    #[test]
    fn untagged_todos_take_the_default_and_open_the_lanes() {
        let note = "## Focus\n- [ ] a\n- [ ] b\n- [ ] \n\n## Notes\n";
        let out = sweep_content(note).expect("defaulting is a change");
        assert!(
            out.contains("- [ ] a #high") && out.contains("- [ ] b #high"),
            "{out}"
        );
        assert!(out.contains("### High"), "{out}");
    }

    #[test]
    fn idempotent_on_already_swept() {
        let note = "## Focus\n- [ ] a\n- [ ] b #urgent\n- [x] c\n\n## Notes\n";
        // organizing once, then sweeping the result, produces no further change
        let once = sweep_content(note).expect("first sweep organizes");
        let twice = sweep_content(&once);
        assert!(
            twice.is_none(),
            "a second sweep of swept content is a no-op"
        );
    }

    #[test]
    fn golden_matches_the_nvim_buffer_sweep() {
        // Byte-for-byte the output the nvim BufWritePre sweep produces for the same input
        // (markdown.lua rebuild_focus_body), locking the two surfaces in parity.
        let note = "## Focus\n- [ ] plain top\n- [ ] task #high\n### Urgent\n- [ ] dropped\n- [ ] \n\n## Notes\nafter\n";
        let expected = "## Focus\n- [ ] \n\n### Urgent\n- [ ] dropped #urgent\n\n### High\n- [ ] plain top #high\n- [ ] task #high\n\n### Low\n\n---\n### Done\n\n## Notes\nafter\n";
        assert_eq!(sweep_content(note).unwrap(), expected);
    }

    #[test]
    fn empty_lanes_are_kept_as_placeholders() {
        // one #high task -> all lane headers + Done are emitted, even the empty ones
        let note = "## Focus\n- [ ] task #high\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        let focus = out.split("## Notes").next().unwrap();
        assert!(
            focus.contains("### Urgent"),
            "empty Urgent lane kept as a column"
        );
        assert!(focus.contains("### High"), "High lane present");
        assert!(focus.contains("### Low"), "empty Low lane kept as a column");
        assert!(focus.contains("### Done"), "empty Done kept");
    }

    #[test]
    fn untagged_task_under_a_lane_inherits_its_tag() {
        // a plain task physically under ### Urgent gets #urgent (drop-to-tag), and stays put
        let note = "## Focus\n### Urgent\n- [ ] dropped here\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        assert!(
            out.contains("- [ ] dropped here #urgent"),
            "inherited the lane's tag"
        );
        let focus = out.split("## Notes").next().unwrap();
        let urgent = focus.find("### Urgent").unwrap();
        let task = focus.find("dropped here").unwrap();
        let high = focus.find("### High").unwrap();
        assert!(task > urgent && task < high, "stays in the Urgent lane");
        // and the inherited tag is stable on a re-sweep (tag now wins, no double-tagging)
        assert!(sweep_content(&out).is_none(), "drop-to-tag is idempotent");
    }

    // -- #idea rows ---------------------------------------------------------------------

    fn idea_note() -> &'static str {
        "\
## Focus
- [ ] ship the build #high
- [ ] a can-kicking level #idea:apociseum
  - drugs make you dizzy
- [ ] a pinball roguelike #idea
- [x] an old idea already done #idea
- [ ] typo project #idea:nosuch
<!-- rollup:start -->
- [ ] mirrored #idea
"
    }

    fn sandbox(tag: &str) -> (PathBuf, Profile) {
        let root = std::env::temp_dir().join(format!("focus-ideas-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("apociseum")).unwrap();
        let p = crate::config::test_profile(root.to_str().unwrap());
        (root, p)
    }

    #[test]
    fn idea_rows_leave_focus_for_their_files() {
        let (root, p) = sandbox("move");
        let log = Logger::new(p.log_file.clone(), false);
        let dir = root.join("apociseum");
        let rest = move_ideas(&p, &log, idea_note(), |n| {
            (n == "apociseum").then(|| dir.clone())
        })
        .unwrap()
        .unwrap();

        // the open idea rows left, with the indented line under the project one
        assert!(!rest.contains("can-kicking"));
        assert!(!rest.contains("drugs make you dizzy"));
        assert!(!rest.contains("pinball"));
        // a done row, an unknown project and the rollup mirror stay put
        assert!(rest.contains("an old idea already done"));
        assert!(rest.contains("typo project #idea:nosuch"));
        assert!(rest.contains("- [ ] mirrored #idea"));
        assert!(rest.contains("ship the build"));

        let proj = fs::read_to_string(dir.join("ideas.md")).unwrap();
        assert!(proj.starts_with("# apociseum - ideas"));
        assert!(
            proj.contains("- [ ] a can-kicking level #idea:apociseum\n  - drugs make you dizzy\n")
        );
        let cross = fs::read_to_string(&p.ideas).unwrap();
        assert!(cross.contains("- [ ] a pinball roguelike #idea\n"));
        assert!(!cross.contains("mirrored"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_rerun_does_not_write_an_idea_twice() {
        let (root, p) = sandbox("rerun");
        let log = Logger::new(p.log_file.clone(), false);
        let none = |_: &str| None;
        move_ideas(&p, &log, idea_note(), none).unwrap();
        // the note write never happened: the same rows are swept again
        move_ideas(&p, &log, idea_note(), none).unwrap();
        let cross = fs::read_to_string(&p.ideas).unwrap();
        assert_eq!(cross.matches("pinball roguelike").count(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_project_tagged_row_moves_to_that_projects_inbox() {
        let (root, p) = sandbox("inbox");
        let log = Logger::new(p.log_file.clone(), false);
        let dir = root.join("apociseum");
        let note = "## Focus\n- [ ] gun sound is off #p:apociseum\n  since the patch\n\
                    - [ ] typo #p:nosuch\n- [ ] just work\n";
        let at = |n: &str| (n == "apociseum").then(|| dir.clone());
        let rest = move_to_inboxes(&p, &log, note, at).unwrap().unwrap();
        assert!(!rest.contains("gun sound"), "{rest}");
        assert!(
            rest.contains("- [ ] typo #p:nosuch"),
            "an unknown project stays"
        );
        assert!(rest.contains("- [ ] just work"));
        let sheet = fs::read_to_string(dir.join("README.md")).unwrap();
        let inbox = sheet.split("## Tasks").next().unwrap();
        assert!(
            inbox.contains("- [ ] gun sound is off\n  since the patch\n"),
            "{sheet}"
        );
        // a rerun over the same note does not write the line twice
        move_to_inboxes(&p, &log, note, at).unwrap();
        let again = fs::read_to_string(dir.join("README.md")).unwrap();
        assert_eq!(again.matches("gun sound").count(), 1, "{again}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_note_with_no_ideas_is_untouched() {
        let (root, p) = sandbox("none");
        let log = Logger::new(p.log_file.clone(), false);
        let note = "## Focus\n- [ ] just work #high\n";
        assert!(move_ideas(&p, &log, note, |_| None).unwrap().is_none());
        assert!(!p.ideas.exists());
        let _ = fs::remove_dir_all(&root);
    }
}
