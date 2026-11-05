//! Sweep a project sheet's `## Tasks` section: one list, most urgent first, then `---` and
//! `### Done`.
//!
//! The release tag is the source of truth, exactly as the priority tag is, and no heading
//! repeats it. Two rules the lane sweep has no equivalent for. A row can never be aimed at a
//! release already closed, so a tag below the sheet's `Version:` goes and the row follows the
//! open version. And `#urgent` is legal only in the open version, so a row aimed later is
//! rewritten to `#high`.

use crate::md;
use crate::projects;
use crate::sheet::{self, V};
use crate::sweep;

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
/// The open version is the sheet's own `Version:` line. An agent board has none, so its rows
/// keep their tags as they are and only the priority sort applies.
pub(crate) fn sweep_sheet(content: &str) -> Option<(String, Vec<String>)> {
    let lines: Vec<&str> = content.lines().collect();
    let span = md::section_span(&lines, sheet::TASKS)?;
    let cur = projects::sheet_version(content);

    let mut report: Vec<String> = Vec::new();
    let mut body: Vec<String> = Vec::new();
    for l in &lines[span.clone()] {
        // Blank lines and the generated `- [ ] ` placeholder are scaffold, not content: the
        // lane rebuild re-emits the placeholder itself.
        if l.trim().is_empty() || md::is_empty_unchecked(l) {
            continue;
        }
        if !md::is_open_task(l) {
            body.push((*l).to_string());
            continue;
        }
        let stale = matches!((sheet::target(l), cur), (Some(t), Some(c)) if t < c);
        if stale {
            report.push(format!(
                "{}: tag dropped, {} closed",
                md::task_text(l),
                md::version_tag(l).unwrap_or_default()
            ));
            body.push(md::split_version(l).0);
        } else if sheet::is_later(l, cur) {
            let (line, note) = cap_priority((*l).to_string());
            report.extend(note);
            body.push(line);
        } else {
            body.push((*l).to_string());
        }
    }

    let refs: Vec<&str> = body.iter().map(String::as_str).collect();
    let mut out: Vec<String> = lines[..span.start]
        .iter()
        .map(|l| (*l).to_string())
        .collect();
    // Canonical tag order, applied once at the end: the retag above and the lane inherit
    // inside `rebuild` add tags at different points, so this is what stops the same task
    // being spelled two ways depending on how it got here.
    out.extend(
        sweep::rebuild_sorted(&refs)
            .iter()
            .map(|l| md::normalize_tags(l)),
    );
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

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "\
# demo
Version: v0.12.1

## Tasks
- [ ] live one #high
- [ ] next one #v0.12.2
- [x] done one <!-- pr:307 -->
";

    fn sweep(c: &str) -> String {
        sweep_sheet(c).expect("sheet reorganizes").0
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
        assert!(out.contains("- [ ] next one #high #v0.12.2\n"), "{out}");
        assert!(out.contains("- [x] done one <!-- pr:307 -->"), "{out}");
    }

    // Sorted, not bucketed: no urgency headings, most urgent first, done at the foot.
    #[test]
    fn the_section_sorts_by_priority_and_keeps_its_done_list() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n\
- [ ] middle #high\n- [ ] last #low\n- [ ] first #urgent\n- [x] shipped <!-- pr:1 -->\n";
        let out = sweep(s);
        assert!(!out.contains("### Urgent"), "no lane headings:\n{out}");
        assert!(
            !out.contains("### High") && !out.contains("### Low"),
            "{out}"
        );
        let (f, m, l) = (
            out.find("first").unwrap(),
            out.find("middle").unwrap(),
            out.find("last").unwrap(),
        );
        assert!(f < m && m < l, "urgent -> high -> low:\n{out}");
        let done = out.find("### Done").unwrap();
        assert!(l < done, "open work above the rule:\n{out}");
        assert!(
            out.find("shipped").unwrap() > done,
            "done at the foot:\n{out}"
        );
    }

    // Equal priority keeps the order the human wrote, so a sweep never reshuffles a list.
    #[test]
    fn tasks_of_equal_priority_keep_their_file_order() {
        let s = "# d\nVersion: v0.1.0\n\n## Tasks\n\
- [ ] alpha #high\n- [ ] beta #high\n- [ ] gamma #high\n";
        let out = sweep(s);
        let (a, b, g) = (
            out.find("alpha").unwrap(),
            out.find("beta").unwrap(),
            out.find("gamma").unwrap(),
        );
        assert!(a < b && b < g, "stable:\n{out}");
    }

    // A tag on a closed release goes: the row follows the open version.
    #[test]
    fn a_tag_naming_a_closed_version_is_dropped() {
        let stale = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] stale #v0.11.0\n";
        let (out, report) = sweep_sheet(stale).unwrap();
        assert!(out.contains("- [ ] stale #high\n"), "{out}");
        assert!(
            report.iter().any(|r| r.contains("#v0.11.0 closed")),
            "{report:?}"
        );
    }

    #[test]
    fn urgent_is_demoted_on_a_row_aimed_later() {
        let s = "# d\nVersion: v0.12.1\n\n## Tasks\n- [ ] fire #urgent #v0.12.2\n";
        let (out, report) = sweep_sheet(s).unwrap();
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
        assert!(sweep_sheet(legacy).is_none());
    }

    #[test]
    fn a_board_with_no_version_line_keeps_its_tags() {
        let board = "# d\n\n## Tasks\n- [ ] a #v0.0.9\n";
        let (out, _) = sweep_sheet(board).expect("a board sweeps");
        assert_eq!(
            out,
            "# d\n\n## Tasks\n- [ ] a #high #v0.0.9\n- [ ] \n\n---\n### Done\n"
        );
    }

    // Byte-for-byte the output the nvim BufWritePre sweep produces for the same input
    // (markdown.lua sweep_tasks), captured from a real headless run. The sweep exists twice,
    // once here and once in the editor, and this is the only thing that can catch them
    // drifting apart. Its sibling in `sweep` pins the `## Focus` half.
    #[test]
    fn golden_matches_the_nvim_task_sweep() {
        let note = "# demo\nVersion: v0.12.1\n\n## Inbox\n\n## Tasks\n\
- [ ] live one #high\n- [x] done one <!-- pr:307 -->\n- [ ] fire #urgent\n\
- [ ] wrapped task here\n      a continuation line\n- [ ] pushed out #v0.12.2\n\
- [ ] burning #urgent #v0.12.3\n- [ ] stale #v0.11.0\n\n## Notes\nprose\n";
        let expected = "# demo\nVersion: v0.12.1\n\n## Inbox\n\n## Tasks\n\
- [ ] fire #urgent\n- [ ] live one #high\n- [ ] wrapped task here #high\n      a continuation line\n\
- [ ] pushed out #high #v0.12.2\n- [ ] burning #high #v0.12.3\n- [ ] stale #high\n- [ ] \n\n\
---\n### Done\n- [x] done one <!-- pr:307 -->\n\n## Notes\nprose\n";
        assert_eq!(sweep(note), expected);
    }

    // The migration case. Nothing emits `### Urgent`/`### High`/`### Low` any more, but
    // `is_scaffold` must keep RECOGNISING them or every sheet written by the previous layout
    // has its leftover headings reclassified as stray prose and shoved into the task list.
    #[test]
    fn leftover_lane_headings_from_the_old_layout_are_removed_not_read_as_prose() {
        let old_layout = "# d\nVersion: v0.1.0\n\n## Tasks\n- [ ] \n\n\
### Urgent\n- [ ] fire #urgent\n\n### High\n- [ ] steady #high\n\n\
### Low\n\n---\n### Done\n- [x] shipped <!-- pr:1 -->\n";
        let out = sweep(old_layout);
        assert!(!out.contains("### Urgent"), "removed:\n{out}");
        assert!(
            !out.contains("### High") && !out.contains("### Low"),
            "{out}"
        );
        // and not turned into tasks or prose
        assert!(!out.contains("- [ ] ### "), "{out}");
        assert!(out.contains("- [ ] fire #urgent\n"), "{out}");
        assert!(out.contains("- [ ] steady #high\n"), "{out}");
        assert!(out.contains("- [x] shipped <!-- pr:1 -->"), "{out}");
        assert!(
            out.find("fire").unwrap() < out.find("steady").unwrap(),
            "still sorted:\n{out}"
        );
        // and it settles in one pass
        assert!(sweep_sheet(&out).is_none(), "idempotent:\n{out}");
    }

    #[test]
    fn sweeping_a_swept_sheet_is_a_no_op() {
        let once = sweep(SHEET);
        assert!(sweep_sheet(&once).is_none(), "settles:\n{once}");
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
}
