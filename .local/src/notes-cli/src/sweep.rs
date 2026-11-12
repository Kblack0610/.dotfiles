//! The priority-lane sweep: a `### Urgent` / `### High` / `### Low` lane each, then `---` and
//! `### Done`. Every lane header is emitted even when empty so the columns stay put as drop
//! targets, and an untagged task dropped under one inherits that lane's tag. The tag is the
//! source of truth; position decides only for a task that has none.
//!
//! The daily note's `## Focus` is laid out here. A project sheet's `## Tasks` is taken apart
//! by the same bucketing ([`task_body`]) and laid out in its sections by `project_sweep`, so
//! one parser answers "which rows, with which detail lines", for both.

use crate::md;

/// Which bucket a line landed in, so an indented follow-on line can land in the same one.
#[derive(Clone, Copy)]
enum Bucket {
    Open(usize),
    Done,
}

/// The number of lanes: the index of the trailing bucket for lines that are no task.
const LANES: usize = md::PRIORITIES.len();

/// Lane index for an open task, else [`LANES`] (no priority tag).
fn lane_of(line: &str) -> usize {
    md::task_priority(line)
        .and_then(|tag| md::PRIORITIES.iter().position(|(_, hash, _)| *hash == tag))
        .unwrap_or(LANES)
}

/// The headings a sheet's `## Tasks` is cut into, above its `---` and `### Done`
/// (`project_sweep`). Scaffold in that layout only: a daily note's `### Now` is the human's.
pub(crate) const TASK_SECTIONS: [&str; 4] = ["### Epics", "### Now", "### Next up", "### Backlog"];

/// A `###` heading or `---` rule this sweep owns, so it is re-emitted only where the sweep
/// puts it and an authored heading elsewhere survives as content.
fn is_scaffold(line: &str, layout: Layout) -> bool {
    let t = line.trim();
    t == "---"
        || t.eq_ignore_ascii_case("### Done")
        || t.eq_ignore_ascii_case("### In progress")
        || md::PRIORITIES
            .iter()
            .any(|(_, _, h)| t.eq_ignore_ascii_case(h))
        || (layout == Layout::Tasks && TASK_SECTIONS.iter().any(|h| t.eq_ignore_ascii_case(h)))
}

/// The lane a scaffold heading opens. `None` for a non-lane scaffold (`---`, `### Done`).
fn scaffold_lane(line: &str) -> Option<usize> {
    let t = line.trim();
    md::PRIORITIES
        .iter()
        .position(|(_, _, h)| t.eq_ignore_ascii_case(h))
}

/// Everything one list body holds, sorted into buckets. The two layouts below differ only
/// in how they EMIT this - the bucketing rule is shared so they cannot disagree about which
/// lane a task is in.
struct Buckets {
    /// One per lane, plus a trailing bucket for lines that are no task: prose on a sheet,
    /// an authored heading or comment in Focus.
    open: Vec<Vec<String>>,
    done: Vec<String>,
    placeholder: Option<String>,
}

/// Rebuild one list body, grouped under a `### <Lane>` heading each, with a trailing
/// `### Done`. This is the `## Focus` layout: the lanes are the whole of it, so a note holds
/// them from the day it is made, and the headings are drop targets, so they are emitted even
/// when empty. Nothing is unlaned: an empty `- [ ]` slot goes, a line of text is a task
/// ([`md::loose_task`]), and a task with no lane takes [`md::FOCUS_DEFAULT_PRIORITY`].
fn rebuild(body: &[&str]) -> Vec<String> {
    let mut b = bucket(body, Layout::Focus, true);
    let mut out: Vec<String> = Vec::new();
    out.extend(b.open[LANES].drain(..));
    for (i, (_, _, heading)) in md::PRIORITIES.iter().enumerate() {
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push((*heading).to_string());
        out.extend(b.open[i].drain(..));
    }
    out.push(String::new());
    out.push("---".to_string());
    out.push("### Done".to_string());
    out.extend(b.done);
    out
}

/// One task row with the indented lines under it (wrapped text, details, child rows).
pub(crate) type Block = Vec<String>;

/// A `## Tasks` body taken apart for `project_sweep` to lay out: the prose lines, the open and
/// closed row blocks, and the empty `- [ ] ` slot if it had one. Open blocks come out grouped
/// by priority and in file order within one, which a stable sort by [`crate::rank`] keeps.
pub(crate) struct TaskBody {
    pub prose: Vec<String>,
    pub open: Vec<Block>,
    pub done: Vec<Block>,
    pub placeholder: Option<String>,
}

/// `retag` gives an untagged row the default priority; without it every row keeps its bytes.
pub(crate) fn task_body(body: &[&str], retag: bool) -> TaskBody {
    let mut b = bucket(body, Layout::Tasks, retag);
    let prose = std::mem::take(&mut b.open[LANES]);
    let open = (0..LANES)
        .flat_map(|i| blocks(std::mem::take(&mut b.open[i])))
        .collect();
    TaskBody {
        prose,
        open,
        done: blocks(b.done),
        placeholder: b.placeholder,
    }
}

/// Split one bucket's lines into row blocks: an indented line belongs to the row above it,
/// which `bucket` already put in the same bucket right after it.
fn blocks(lines: Vec<String>) -> Vec<Block> {
    let mut out: Vec<Block> = Vec::new();
    for l in lines {
        match out.last_mut() {
            Some(b) if l.starts_with(char::is_whitespace) => b.push(l),
            _ => out.push(vec![l]),
        }
    }
    out
}

/// Which list a body is, for the two things they answer differently: what a line of text is,
/// and the lane of a task nobody placed.
#[derive(Clone, Copy, PartialEq)]
enum Layout {
    Focus,
    Tasks,
}

/// Put a top-level `row` in bucket `i`, after the group break pending there (see [`bucket`]).
/// Returns `i`, the lane the row landed in.
fn land(open: &mut [Vec<String>], pending: &mut [bool], i: usize, row: String) -> usize {
    if std::mem::take(&mut pending[i]) && !open[i].is_empty() {
        open[i].push(String::new());
    }
    open[i].push(row);
    i
}

/// Sort one list body into buckets. Shared by both layouts.
fn bucket(body: &[&str], layout: Layout, retag: bool) -> Buckets {
    let default = match layout {
        Layout::Focus => md::FOCUS_DEFAULT_PRIORITY,
        Layout::Tasks => md::DEFAULT_PRIORITY,
    };
    let mut open: Vec<Vec<String>> = vec![Vec::new(); LANES + 1];
    let mut done: Vec<String> = Vec::new();
    let mut placeholder: Option<String> = None;
    let mut cur_lane: Option<usize> = None;
    // Where the last top-level line went, so its indented children follow it.
    let mut last: Option<Bucket> = None;
    // Group breaks (Focus only): a blank after a row marks a break in the lane it sits in (its
    // heading, else the lane of the open row above it), kept before the NEXT row that lands in
    // that lane when one is already there. So the break survives the row beside it being
    // checked off or re-tagged away, never opens a lane or goes to Done, and a blank between a
    // row and its indented note is no break (human, 2026-11-12:
    // "sometimes I need to still organize a group").
    let mut pending = vec![false; LANES + 1];
    let mut last_open: Option<usize> = None;

    for l in body {
        let t = l.trim();
        if t.is_empty() && layout == Layout::Focus {
            if let Some(i) = last_open.map(|o| cur_lane.unwrap_or(o)) {
                pending[i] = true;
            }
            continue;
        }
        if is_scaffold(l, layout) {
            cur_lane = scaffold_lane(l);
            last = None;
            last_open = None;
            pending.fill(false);
            continue;
        }
        // An indented line belongs to the task above it: a wrapped continuation, or a
        // subtask. Bucketing it on its own would tear it off its parent and float it to the
        // top of the list.
        if !t.is_empty() && l.starts_with(char::is_whitespace) {
            if let Some(b) = last {
                pending.fill(false);
                match b {
                    Bucket::Open(i) => open[i].push((*l).to_string()),
                    Bucket::Done => done.push((*l).to_string()),
                }
                continue;
            }
        }
        // Past the indent check, so a note under a task stays a note. What is left and indented
        // has no task above it, which makes it a line of its own.
        let task = if layout == Layout::Focus {
            md::loose_task(l)
        } else {
            None
        };
        let l = task.as_deref().unwrap_or(l);
        if md::is_checked(l) {
            done.push(l.to_string());
            last = Some(Bucket::Done);
        } else if md::is_empty_unchecked(l) {
            placeholder = Some(l.to_string());
            last = None;
        } else if md::is_task(l) {
            let i = match md::task_priority(l) {
                Some(_) => lane_of(l), // the tag is the source of truth
                None => {
                    // Untagged: inherit the lane it was dropped under, else take the
                    // default. A Focus task leaves here TAGGED - an open task with no stated
                    // priority used to sort above `### Urgent`. A sheet row with no lane over
                    // it stays untagged: it is untriaged, and a default `#high` would hide that
                    // (human, 2026-11-09: every row gets a real priority from triage).
                    let i = cur_lane.unwrap_or(default);
                    let tag = retag && (layout == Layout::Focus || cur_lane.is_some());
                    let row = if tag {
                        md::add_tag(l, md::PRIORITIES[i].1)
                    } else {
                        l.to_string()
                    };
                    last_open = Some(land(&mut open, &mut pending, i, row));
                    last = Some(Bucket::Open(i));
                    continue;
                }
            };
            last_open = Some(land(&mut open, &mut pending, i, l.to_string()));
            last = Some(Bucket::Open(i));
        } else if !t.is_empty() {
            // a stray prose line stays above the lists
            last_open = Some(land(&mut open, &mut pending, LANES, l.to_string()));
            last = Some(Bucket::Open(LANES));
        }
    }
    Buckets {
        open,
        done,
        placeholder,
    }
}

/// Sweep the one `## <heading>` section `pred` accepts, leaving the rest of `content` alone.
/// `None` when the section is absent or already organized.
///
/// The section ends at the next H2 OR at [`md::ROLLUP_START`]: the mirrored block after that
/// sentinel is generated, not authored, so it is left in place.
pub(crate) fn sweep_section(content: &str, pred: impl Fn(&str) -> bool) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.iter().position(|l| {
        l.strip_prefix("## ")
            .map(|r| pred(r.trim()))
            .unwrap_or(false)
    })?;
    let end = md::section_end(&lines, start + 1);
    let mut body: Vec<&str> = lines[start + 1..end].to_vec();
    while body.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        body.pop();
    }
    let rebuilt = rebuild(&body);

    let mut out: Vec<String> = lines[..=start].iter().map(|s| s.to_string()).collect();
    out.extend(rebuilt);
    out.push(String::new()); // one blank before the next section / rollup block
    out.extend(lines[end..].iter().map(|s| s.to_string()));

    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    (joined != content).then_some(joined)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn focus(body: &str) -> String {
        sweep_section(body, |h| h.eq_ignore_ascii_case("Focus")).unwrap()
    }

    // A tag written past the trailing marker is invisible to `task_text`, which truncates at
    // the first `<!--` before stripping tags. It would then leak as raw `#urgent` onto every
    // board row and cockpit line. Every closed row on a project sheet carries a `pr:` marker.
    #[test]
    fn an_inherited_tag_lands_before_the_trailing_marker() {
        let out = focus("## Focus\n### Urgent\n- [ ] dropped <!-- pr:307 -->\n\n## Notes\n");
        assert!(
            out.contains("- [ ] dropped #urgent <!-- pr:307 -->"),
            "tag belongs before the marker:\n{out}"
        );
        assert!(
            !out.contains("--> #urgent"),
            "never past the marker:\n{out}"
        );
        // and the display path agrees: no tag survives into the rendered text
        assert_eq!(
            md::task_text("- [ ] dropped #urgent <!-- pr:307 -->"),
            "dropped"
        );
    }

    // Re-tagging an already-tagged line would double it on every sweep.
    #[test]
    fn add_tag_is_idempotent_through_a_re_sweep() {
        let once = focus("## Focus\n### Urgent\n- [ ] dropped <!-- pr:307 -->\n\n## Notes\n");
        assert!(
            sweep_section(&once, |h| h.eq_ignore_ascii_case("Focus")).is_none(),
            "a second sweep of swept content is a no-op:\n{once}"
        );
    }

    // An indented line belongs to the task above it. Bucketing it alone tore a wrapped
    // continuation off its parent and floated it to the top of the list.
    #[test]
    fn a_wrapped_continuation_stays_with_its_task() {
        let out = focus(
            "## Focus\n- [ ] plain\n- [ ] outlook integration #high\n      needs OAuth2 first\n\n## Notes\n",
        );
        assert!(
            out.contains("- [ ] outlook integration #high\n      needs OAuth2 first"),
            "continuation stays attached:\n{out}"
        );
        let high = out.find("### High").unwrap();
        assert!(
            out.find("needs OAuth2").unwrap() > high,
            "and inside the lane:\n{out}"
        );
    }

    // Same rule for a nested subtask, which `is_task` would otherwise bucket on its own.
    #[test]
    fn a_nested_subtask_stays_under_its_parent() {
        let out = focus(
            "## Focus\n- [ ] parent #urgent\n    - [ ] child\n    - [x] done child\n\n## Notes\n",
        );
        assert!(
            out.contains("- [ ] parent #urgent\n    - [ ] child\n    - [x] done child"),
            "the block stays contiguous:\n{out}"
        );
        // the done CHILD is not promoted into the Done list away from its parent
        let done = out.find("### Done").unwrap();
        assert!(
            out.find("done child").unwrap() < done,
            "child stays put:\n{out}"
        );
    }

    // A blank after a row is a group break the human made, kept in its lane before the next
    // row that lands there: it survives the row above it being checked off (b) or the row below
    // it re-tagged away (c), a run collapses to one, none opens a lane (u) or goes to Done, a
    // blank before an indented note is no break, and a re-sweep changes nothing.
    // tests/integ/notes_save_sweep.bats ("a save keeps the blank lines that group a lane")
    // runs the same input through markdown.lua.
    #[test]
    fn golden_blank_lines_group_rows_inside_a_lane() {
        let note = "## Focus\n### High\n- [ ] h1 #high\n### Low\n- [ ] a #low\n- [x] b #low\n\n- [ ] c #urgent\n- [ ] d #low\n\n    its note\n- [ ] e #low\n\n\n- [ ] f #low\n### Urgent\n\n- [ ] u #urgent\n\n- [x] g\n\n- [x] h\n\n## Notes\n";
        let expected = "## Focus\n### Urgent\n- [ ] c #urgent\n- [ ] u #urgent\n\n### High\n- [ ] h1 #high\n\n### Low\n- [ ] a #low\n\n- [ ] d #low\n    its note\n- [ ] e #low\n\n- [ ] f #low\n\n---\n### Done\n- [x] b #low\n- [x] g\n- [x] h\n\n## Notes\n";
        let out = focus(note);
        assert_eq!(out, expected);
        assert!(sweep_section(&out, |h| h.eq_ignore_ascii_case("Focus")).is_none());
    }

    // Byte-for-byte the output the nvim BufWritePre sweep produces for the same input
    // (markdown.lua rebuild_focus_body), covering BOTH behaviours this module changed: a tag
    // inherited onto a line that carries a marker, and indented children staying with their
    // parent. The sibling golden in focus_sweep pins the no-marker, no-indent case; between
    // them the two implementations cannot drift without a test going red.
    #[test]
    fn golden_matches_the_nvim_buffer_sweep_with_markers_and_children() {
        let note = "## Focus\n- [ ] parent #urgent\n    - [ ] child\n    - [x] done child\n- [ ] outlook integration #high\n      needs OAuth2 first\n### Urgent\n- [ ] dropped <!-- pr:307 -->\n\n## Notes\nafter\n";
        let expected = "## Focus\n### Urgent\n- [ ] parent #urgent\n    - [ ] child\n    - [x] done child\n- [ ] dropped #urgent <!-- pr:307 -->\n\n### High\n- [ ] outlook integration #high\n      needs OAuth2 first\n\n### Low\n\n---\n### Done\n\n## Notes\nafter\n";
        assert_eq!(focus(note), expected);
    }
}
