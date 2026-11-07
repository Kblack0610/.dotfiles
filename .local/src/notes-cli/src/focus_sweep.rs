//! `notes focus sweep` — reorganize today's `## Focus` by priority + status, so a task
//! moves between lanes as its `#urgent`/`#high`/`#low` tag is set or its
//! checkbox is checked: `### Urgent` / `### High` / `### Low` (open tasks, in-priority
//! order), done (`[x]`) under `--- / ### Done`. An in-progress `[/]` task keeps its mark
//! inside its priority lane. Empty lane headers + Done persist as drop targets, and an
//! untagged task dropped under a lane header inherits that lane's tag.
//!
//! Every line in Focus is a task: a bare bullet or a plain line becomes `- [ ] <text>` and
//! stays, with anything indented under it, so a paste is carried like any row instead of
//! being lost with its day. A task in no lane files under `### Low`.
//!
//! This mirrors the nvim buffer sweep (markdown.lua rebuild_focus_body) so that
//! tagging/checking a task from the cockpit organizes the note exactly like cycling it in
//! the editor does — the note stays grouped no matter which surface you touch. Only the
//! AUTHORED region is reorganized: a rollup mirror (everything from md::ROLLUP_START on)
//! is left untouched at the end of the section.
//!
//! The sweep never moves a row out of Focus, so the note is written only to regroup it. A row
//! is ingested only when asked, by `notes focus ingest` (focus.rs), which hands it to the
//! outbox and its sweep.
//!
//! Lives in its own module to stay clear of a concurrent focus.rs refactor.

use crate::config::Profile;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use crate::sweep;
use anyhow::{bail, Result};
use std::fs;

// The priority lanes are md::PRIORITIES (the single source of truth, most-urgent first),
// shared with tag detection. Checked tasks go under ### Done; each open task otherwise
// buckets by its tag. The nvim sweep (markdown.lua LANES) mirrors the same set.

/// Pure core: reorganize the ## Focus section of `content` by status. `None` when the
/// section is absent or already organized (no change).
///
/// The lane model itself lives in `sweep`, shared with the project-sheet sweep. Focus
/// offers all three lanes.
pub(crate) fn sweep_content(content: &str) -> Option<String> {
    sweep::sweep_section(content, |h| h.eq_ignore_ascii_case("Focus"))
}

/// `content` with its `## Focus` filed: what a writer puts on disk, so a row it adds under the
/// heading never sits above the lanes.
pub(crate) fn filed(content: String) -> String {
    sweep_content(&content).unwrap_or(content)
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
    crate::ingest::record(p, &crate::ingest::Event::new("toggled", "focus", "", query));
    Ok(0)
}

/// notes focus sweep: organize today's `## Focus` by status in place. It moves nothing out
/// of Focus: a row leaves only when someone runs `notes focus ingest` on it.
pub fn sweep(p: &Profile, log: &Logger) -> Result<i32> {
    let note = daily::today_path(p);
    if !note.exists() {
        return Ok(0);
    }
    let content = fs::read_to_string(&note)?;
    if let Some(new) = sweep_content(&content) {
        fs::write(&note, new)?;
        log.info("focus", "swept ## Focus by status");
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
        // an untagged task takes the Focus default and lands in Low, not above the lanes
        let untagged = focus.find("untagged one").unwrap();
        assert!(out.contains("- [ ] untagged one #low"), "defaulted:\n{out}");
        assert!(untagged > low && untagged < done, "in the Low lane:\n{out}");
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

    // The lanes are the whole of Focus, so a note with nothing in it still has them, and the
    // empty `- [ ]` slot that used to sit above them goes.
    #[test]
    fn a_note_with_only_the_slot_opens_on_the_bare_lanes() {
        let lanes = "## Focus\n\n### Urgent\n\n### High\n\n### Low\n\n---\n### Done\n\n## Notes\n";
        assert_eq!(
            sweep_content("## Focus\n- [ ] \n\n## Notes\n").unwrap(),
            lanes
        );
        assert_eq!(sweep_content("## Focus\n\n## Notes\n").unwrap(), lanes);
        assert!(
            sweep_content(lanes).is_none(),
            "the bare lanes are the sorted form"
        );
    }

    #[test]
    fn a_task_in_no_lane_files_under_low() {
        let note = "## Focus\n- [ ] a\n- [ ] b\n- [ ] \n\n## Notes\n";
        let out = sweep_content(note).expect("defaulting is a change");
        let low = out.find("### Low").unwrap();
        assert!(
            out.contains("- [ ] a #low") && out.contains("- [ ] b #low"),
            "{out}"
        );
        assert!(out.find("- [ ] a").unwrap() > low, "{out}");
    }

    // A bare bullet and a plain line both stay in Focus as open tasks, in the lane they sit
    // under, else Low; indented notes stay under them. Measured before this: 37 pasted lines
    // in one note (2026-11-04) were read by nothing and lost with their day.
    #[test]
    fn every_line_of_text_becomes_a_task_where_it_stands() {
        let note = "## Focus\nplain line\n- bare bullet\n    a note under it\n* star bullet\n\n### Urgent\ndropped in urgent\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        let focus = out.split("## Notes").next().unwrap();
        let (urgent, low) = (
            focus.find("### Urgent").unwrap(),
            focus.find("### Low").unwrap(),
        );
        assert!(focus.contains("- [ ] dropped in urgent #urgent"), "{out}");
        assert!(focus.find("dropped in urgent").unwrap() > urgent, "{out}");
        assert!(
            focus.contains("- [ ] plain line #low\n- [ ] bare bullet #low\n    a note under it\n- [ ] star bullet #low"),
            "{out}"
        );
        assert!(focus.find("plain line").unwrap() > low, "{out}");
        assert!(
            sweep_content(&out).is_none(),
            "the rewrite is idempotent:\n{out}"
        );
    }

    #[test]
    fn a_line_that_names_a_priority_files_by_it() {
        let out = sweep_content("## Focus\nfix the bar #urgent\n\n## Notes\n").unwrap();
        assert!(
            out.contains("### Urgent\n- [ ] fix the bar #urgent"),
            "{out}"
        );
    }

    // A heading, a comment and a rule are not text to act on, and neither is a bullet with
    // nothing in it. An indented line with no task above it has nothing to be a note of.
    #[test]
    fn only_text_becomes_a_task() {
        let note =
            "## Focus\n### Parked\n<!-- kept -->\n-\n### Urgent\n    orphan note\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        assert!(
            out.contains("### Parked\n<!-- kept -->\n\n### Urgent\n- [ ] orphan note #urgent"),
            "{out}"
        );
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
        // tests/integ/notes_save_sweep.bats runs the same input through the real plugin.
        let note = "## Focus\n- [ ] plain top\n- [ ] task #high\n- bare bullet\n    its note\nplain line\n### Urgent\n- [ ] dropped\ntyped here\n- [ ] \n\n## Notes\nafter\n";
        let expected = "## Focus\n\n### Urgent\n- [ ] dropped #urgent\n- [ ] typed here #urgent\n\n### High\n- [ ] task #high\n\n### Low\n- [ ] plain top #low\n- [ ] bare bullet #low\n    its note\n- [ ] plain line #low\n\n---\n### Done\n\n## Notes\nafter\n";
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
}
