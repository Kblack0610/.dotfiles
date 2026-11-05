//! The priority-lane sweep: untagged tasks on top, then a `### Urgent` / `### High` /
//! `### Low` lane each, then `---` and `### Done`. Every lane header is emitted even when
//! empty so the columns stay put as drop targets, and an untagged task dropped under one
//! inherits that lane's tag. The tag is the source of truth; position decides only for a
//! task that has none.
//!
//! Apart from `focus_sweep` because the daily note's `## Focus` is not the only list with
//! urgency in it: a project sheet's `## Tasks` section sorts the same way, and a second copy
//! would be a second answer to "which lane is this task in".

use crate::md;

/// Which bucket a line landed in, so an indented follow-on line can land in the same one.
#[derive(Clone, Copy)]
enum Bucket {
    Open(usize),
    Done,
}

/// The number of lanes: the index of the trailing untagged bucket.
const LANES: usize = md::PRIORITIES.len();

/// Lane index for an open task, else [`LANES`] (untagged).
fn lane_of(line: &str) -> usize {
    md::task_priority(line)
        .and_then(|tag| md::PRIORITIES.iter().position(|(_, hash, _)| *hash == tag))
        .unwrap_or(LANES)
}

/// A `###` heading or `---` rule this sweep owns, so it is re-emitted only where the sweep
/// puts it and an authored heading elsewhere survives as content.
fn is_scaffold(line: &str) -> bool {
    let t = line.trim();
    t == "---"
        || t.eq_ignore_ascii_case("### Done")
        || t.eq_ignore_ascii_case("### In progress")
        || md::PRIORITIES
            .iter()
            .any(|(_, _, h)| t.eq_ignore_ascii_case(h))
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
    /// One per lane, plus a trailing bucket for prose (and anything untagged that the
    /// default could not apply to).
    open: Vec<Vec<String>>,
    done: Vec<String>,
    placeholder: Option<String>,
    had_scaffold: bool,
}

impl Buckets {
    fn any_tagged(&self) -> bool {
        self.open[..LANES].iter().any(|b| !b.is_empty())
    }
}

/// Rebuild one list body, grouped under a `### <Lane>` heading each, with a trailing
/// `### Done`. This is the `## Focus` layout: the headings are drop targets, so they are
/// emitted even when empty.
///
/// `None` when there is nothing to organize - that shape is already the sorted form, and
/// rewriting it would churn the file. It is what keeps a fresh daily note from being born
/// full of empty headers.
fn rebuild(body: &[&str]) -> Option<Vec<String>> {
    let mut b = bucket(body);
    if !b.any_tagged() && b.done.is_empty() && !b.had_scaffold {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    out.extend(b.open[LANES].drain(..));
    out.push(b.placeholder.take().unwrap_or_else(|| "- [ ] ".to_string()));
    for (i, (_, _, heading)) in md::PRIORITIES.iter().enumerate() {
        out.push(String::new());
        out.push((*heading).to_string());
        out.extend(b.open[i].drain(..));
    }
    out.push(String::new());
    out.push("---".to_string());
    out.push("### Done".to_string());
    out.extend(b.done);
    Some(out)
}

/// Rebuild one list body as a single list SORTED by priority, with a trailing `### Done`.
/// This is the `## Tasks` layout.
///
/// A project sheet does not earn the headings. Measured on the live vault before this
/// landed: 84 open tasks across 15 sheets, 16 of them tagged - so three headings and a rule
/// were scaffolding two real groups, and notes-cockpit rendered 13 tasks above an empty
/// `### Urgent`. The daily note is the opposite shape (16 of 17 tagged, every lane full),
/// which is why it keeps them.
///
/// Always emits: the section's `### Done` is part of it, not something that appears once
/// there is enough to organize.
pub(crate) fn rebuild_sorted(body: &[&str]) -> Vec<String> {
    let mut b = bucket(body);
    let mut out: Vec<String> = Vec::new();
    // Prose first, above the task list, where it reads as a note about the list.
    out.extend(b.open[LANES].drain(..));
    // Then every open task, most urgent first. `drain` in lane order preserves file order
    // within a lane, so a sort never reshuffles two tasks of equal priority.
    for i in 0..LANES {
        out.extend(b.open[i].drain(..));
    }
    out.push(b.placeholder.take().unwrap_or_else(|| "- [ ] ".to_string()));
    out.push(String::new());
    out.push("---".to_string());
    out.push("### Done".to_string());
    out.extend(b.done);
    out
}

/// Sort one list body into buckets. Shared by both layouts.
fn bucket(body: &[&str]) -> Buckets {
    let mut open: Vec<Vec<String>> = vec![Vec::new(); LANES + 1];
    let mut done: Vec<String> = Vec::new();
    let mut placeholder: Option<String> = None;
    let mut had_scaffold = false;
    let mut cur_lane: Option<usize> = None;
    // Where the last top-level line went, so its indented children follow it.
    let mut last: Option<Bucket> = None;

    for l in body {
        let t = l.trim();
        if is_scaffold(l) {
            had_scaffold = true;
            cur_lane = scaffold_lane(l);
            last = None;
            continue;
        }
        // An indented line belongs to the task above it: a wrapped continuation, or a
        // subtask. Bucketing it on its own would tear it off its parent and float it to the
        // top of the list.
        if !t.is_empty() && l.starts_with(char::is_whitespace) {
            if let Some(b) = last {
                match b {
                    Bucket::Open(i) => open[i].push((*l).to_string()),
                    Bucket::Done => done.push((*l).to_string()),
                }
                continue;
            }
        }
        if md::is_checked(l) {
            done.push((*l).to_string());
            last = Some(Bucket::Done);
        } else if md::is_empty_unchecked(l) {
            placeholder = Some((*l).to_string());
            last = None;
        } else if md::is_task(l) {
            let i = match md::task_priority(l) {
                Some(_) => lane_of(l), // the tag is the source of truth
                None => {
                    // Untagged: inherit the lane it was dropped under, else take the
                    // default. Either way it leaves here TAGGED - an open task with no
                    // stated priority used to sort above `### Urgent`, so a task nobody had
                    // thought about outranked one explicitly marked urgent.
                    let i = cur_lane.unwrap_or(md::DEFAULT_PRIORITY);
                    open[i].push(md::add_tag(l, md::PRIORITIES[i].1));
                    last = Some(Bucket::Open(i));
                    continue;
                }
            };
            open[i].push((*l).to_string());
            last = Some(Bucket::Open(i));
        } else if !t.is_empty() {
            // a stray prose line stays with the untagged bucket
            open[LANES].push((*l).to_string());
            last = Some(Bucket::Open(LANES));
        }
    }
    Buckets {
        open,
        done,
        placeholder,
        had_scaffold,
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
    let rebuilt = rebuild(&body)?;

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

    // Byte-for-byte the output the nvim BufWritePre sweep produces for the same input
    // (markdown.lua rebuild_focus_body), covering BOTH behaviours this module changed: a tag
    // inherited onto a line that carries a marker, and indented children staying with their
    // parent. The sibling golden in focus_sweep pins the no-marker, no-indent case; between
    // them the two implementations cannot drift without a test going red.
    #[test]
    fn golden_matches_the_nvim_buffer_sweep_with_markers_and_children() {
        let note = "## Focus\n- [ ] parent #urgent\n    - [ ] child\n    - [x] done child\n- [ ] outlook integration #high\n      needs OAuth2 first\n### Urgent\n- [ ] dropped <!-- pr:307 -->\n\n## Notes\nafter\n";
        let expected = "## Focus\n- [ ] \n\n### Urgent\n- [ ] parent #urgent\n    - [ ] child\n    - [x] done child\n- [ ] dropped #urgent <!-- pr:307 -->\n\n### High\n- [ ] outlook integration #high\n      needs OAuth2 first\n\n### Low\n\n---\n### Done\n\n## Notes\nafter\n";
        assert_eq!(focus(note), expected);
    }
}
