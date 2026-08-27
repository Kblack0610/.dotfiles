//! The priority-lane sweep: untagged tasks on top, then a `### Urgent` / `### High` /
//! `### Low` lane each, then `---` and `### Done`. Every lane header is emitted even when
//! empty so the columns stay put as drop targets, and an untagged task dropped under one
//! inherits that lane's tag. The tag is the source of truth; position decides only for a
//! task that has none.
//!
//! Apart from `focus_sweep` because the daily note's `## Focus` is not the only list with
//! urgency in it: a project sheet's `## Wave` sections sweep the same way, and a second copy
//! would be a second answer to "which lane is this task in". `lanes` is a parameter so a
//! caller can offer fewer than three - a planned wave has no legal Urgent lane, so it must
//! not render one as a drop target.

use crate::md;

/// One lane: `(bare word, #hashtag, "### Heading")`. Always a slice of [`md::PRIORITIES`].
pub(crate) type Lane = (&'static str, &'static str, &'static str);

/// Which bucket a line landed in, so an indented follow-on line can land in the same one.
#[derive(Clone, Copy)]
enum Bucket {
    Open(usize),
    Done,
}

/// Lane index for an open task within `lanes`, else `lanes.len()` (untagged).
fn lane_of(line: &str, lanes: &[Lane]) -> usize {
    match md::task_priority(line) {
        Some(tag) => lanes
            .iter()
            .position(|(_, hash, _)| *hash == tag)
            // A tag naming a lane this list does not offer (an `#urgent` line on a planned
            // wave) sorts into the most urgent lane that IS offered, rather than falling to
            // the untagged bucket where it would read as unprioritized.
            .unwrap_or(0),
        None => lanes.len(),
    }
}

/// Index of the default lane within `lanes`, falling back to the most urgent one offered.
///
/// `lanes` can be a sub-slice - a planned wave offers no Urgent lane - so the default has to
/// be located by name rather than by the index it holds in `md::PRIORITIES`.
fn default_lane(lanes: &[Lane]) -> usize {
    lanes
        .iter()
        .position(|(_, hash, _)| *hash == md::default_priority())
        .unwrap_or(0)
}

/// A `###` heading or `---` rule this sweep owns, so it is re-emitted only where the sweep
/// puts it and an authored heading elsewhere survives as content.
///
/// Checks ALL of [`md::PRIORITIES`], not just `lanes`: a leftover `### Urgent` on a list that
/// no longer offers that lane still has to be recognized and removed, or it would be treated
/// as stray prose and pushed into the task list.
fn is_scaffold(line: &str) -> bool {
    let t = line.trim();
    t == "---"
        || t.eq_ignore_ascii_case("### Done")
        || t.eq_ignore_ascii_case("### In progress")
        || md::PRIORITIES
            .iter()
            .any(|(_, _, h)| t.eq_ignore_ascii_case(h))
}

/// The lane a scaffold heading opens, expressed as an index into `lanes`. `None` for a
/// non-lane scaffold (`---`, `### Done`). A heading naming a lane outside `lanes` clamps to
/// the most urgent one offered, so a task dropped under it is tagged with a lane that
/// actually exists and a second sweep leaves it alone.
fn scaffold_lane(line: &str, lanes: &[Lane]) -> Option<usize> {
    let t = line.trim();
    let rank = md::PRIORITIES
        .iter()
        .position(|(_, _, h)| t.eq_ignore_ascii_case(h))?;
    Some(
        lanes
            .iter()
            .position(|l| l.0 == md::PRIORITIES[rank].0)
            .unwrap_or(0),
    )
}

/// Rebuild one list body, grouped by priority lane with a trailing `### Done`.
///
/// `None` when there is nothing to organize (only untagged todos, no done task, no leftover
/// scaffold) - that shape is already the sorted form, and rewriting it would churn the file.
pub(crate) fn rebuild(body: &[&str], lanes: &[Lane]) -> Option<Vec<String>> {
    rebuild_inner(body, lanes, false)
}

/// Like [`rebuild`], but always emits the scaffold, even for a body with nothing to organize.
///
/// A wave section's lanes have to exist from the moment the wave does: they are where you
/// drop a task to prioritize it, and a wave that renders as a flat list offers nowhere to
/// drop. `## Focus` is the other way round - it stays unstyled until you first tag something,
/// so a brand new daily note is not born full of empty headers.
pub(crate) fn rebuild_scaffolded(body: &[&str], lanes: &[Lane]) -> Vec<String> {
    rebuild_inner(body, lanes, true).expect("forced rebuild always produces a body")
}

fn rebuild_inner(body: &[&str], lanes: &[Lane], force: bool) -> Option<Vec<String>> {
    let mut open: Vec<Vec<String>> = vec![Vec::new(); lanes.len() + 1];
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
            cur_lane = scaffold_lane(l, lanes);
            last = None;
            continue;
        }
        // An indented line belongs to the task above it: a wrapped continuation, or a
        // subtask. Bucketing it on its own would tear it off its parent and float it to the
        // top of the list. Focus tasks are short enough that this rarely fires; a project
        // sheet with wrapped task text hits it on the first sweep.
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
                Some(_) => lane_of(l, lanes), // the tag is the source of truth
                None => {
                    // Untagged: inherit the lane it was dropped under, else take the
                    // default. Either way it leaves here TAGGED - an open task with no
                    // stated priority used to sort above `### Urgent`, so a task nobody had
                    // thought about outranked one explicitly marked urgent.
                    let i = cur_lane.unwrap_or_else(|| default_lane(lanes));
                    open[i].push(md::add_tag(l, lanes[i].1));
                    last = Some(Bucket::Open(i));
                    continue;
                }
            };
            open[i].push((*l).to_string());
            last = Some(Bucket::Open(i));
        } else if !t.is_empty() {
            // a stray prose line stays with the untagged top bucket
            open[lanes.len()].push((*l).to_string());
            last = Some(Bucket::Open(lanes.len()));
        }
    }

    let tagged = open[..lanes.len()].iter().any(|b| !b.is_empty());
    if !force && !tagged && done.is_empty() && !had_scaffold {
        return None;
    }

    let mut out: Vec<String> = Vec::new();
    out.extend(open[lanes.len()].drain(..));
    out.push(placeholder.unwrap_or_else(|| "- [ ] ".to_string()));
    for (i, (_, _, heading)) in lanes.iter().enumerate() {
        out.push(String::new());
        out.push((*heading).to_string());
        out.extend(open[i].drain(..));
    }
    out.push(String::new());
    out.push("---".to_string());
    out.push("### Done".to_string());
    out.extend(done);
    Some(out)
}

/// Sweep the one `## <heading>` section `pred` accepts, leaving the rest of `content` alone.
/// `None` when the section is absent or already organized.
///
/// The section ends at the next H2 OR at [`md::ROLLUP_START`]: the mirrored block after that
/// sentinel is generated, not authored, so it is left in place.
pub(crate) fn sweep_section(
    content: &str,
    pred: impl Fn(&str) -> bool,
    lanes: &[Lane],
) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.iter().position(|l| {
        l.strip_prefix("## ")
            .map(|r| pred(r.trim()))
            .unwrap_or(false)
    })?;
    let mut end = lines.len();
    for (i, l) in lines.iter().enumerate().skip(start + 1) {
        if l.starts_with("## ") || l.trim() == md::ROLLUP_START {
            end = i;
            break;
        }
    }
    let mut body: Vec<&str> = lines[start + 1..end].to_vec();
    while body.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        body.pop();
    }
    let rebuilt = rebuild(&body, lanes)?;

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
        sweep_section(body, |h| h.eq_ignore_ascii_case("Focus"), &md::PRIORITIES).unwrap()
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
            sweep_section(&once, |h| h.eq_ignore_ascii_case("Focus"), &md::PRIORITIES).is_none(),
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

    // A planned wave offers no Urgent lane, so it must not render one as a drop target.
    #[test]
    fn a_shorter_lane_set_renders_only_those_lanes() {
        let out = sweep_section(
            "## Focus\n- [ ] a #high\n\n## Notes\n",
            |h| h.eq_ignore_ascii_case("Focus"),
            &md::PRIORITIES[1..],
        )
        .unwrap();
        let body = out.split("## Notes").next().unwrap();
        assert!(
            !body.contains("### Urgent"),
            "no illegal drop target:\n{out}"
        );
        assert!(body.contains("### High") && body.contains("### Low"));
    }

    // A leftover heading for a lane no longer offered still has to be recognised as scaffold
    // and removed, and the task under it re-tagged to a lane that exists - otherwise it would
    // be read as stray prose, and a second sweep would keep moving it.
    #[test]
    fn a_dropped_lane_heading_is_removed_and_its_task_re_tagged() {
        let lanes = &md::PRIORITIES[1..];
        let out = sweep_section(
            "## Focus\n### Urgent\n- [ ] was urgent\n\n## Notes\n",
            |h| h.eq_ignore_ascii_case("Focus"),
            lanes,
        )
        .unwrap();
        assert!(!out.contains("### Urgent"), "heading gone:\n{out}");
        assert!(out.contains("- [ ] was urgent #high"), "re-tagged:\n{out}");
        assert!(
            sweep_section(&out, |h| h.eq_ignore_ascii_case("Focus"), lanes).is_none(),
            "and it settles:\n{out}"
        );
    }
}
