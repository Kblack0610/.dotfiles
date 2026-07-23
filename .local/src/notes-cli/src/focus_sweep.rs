//! `notes focus sweep` — reorganize today's `## Focus` by priority + status, so a task
//! moves between lanes as its `#urgent`/`#high`/`#low` tag is cycled or its
//! checkbox is checked: untagged todos on top, then `### Urgent` / `### High` /
//! `### Low` (open tasks, in-priority order), done (`[x]`) under
//! `--- / ### Done`. An in-progress `[/]` task keeps its mark inside its priority lane.
//!
//! This mirrors the nvim buffer sweep (markdown.lua rebuild_focus_body) so that
//! tagging/checking a task from the cockpit organizes the note exactly like cycling it in
//! the editor does — the note stays grouped no matter which surface you touch. Only the
//! AUTHORED region is reorganized: a rollup mirror (everything from md::ROLLUP_START on)
//! is left untouched at the end of the section.
//!
//! Lives in its own module to stay clear of a concurrent focus.rs refactor.

use crate::config::Profile;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use std::fs;

// The priority lanes are md::PRIORITIES (the single source of truth, most-urgent first),
// shared with tag detection. Untagged open tasks (rank == PRIORITIES.len()) stay unheaded on
// top; checked tasks go under ### Done; each open task otherwise buckets by its tag. The
// nvim sweep (markdown.lua LANES) mirrors the same set.

/// Lane index for an open task: 0..PRIORITIES.len() by priority tag, else PRIORITIES.len()
/// (untagged).
fn lane_of(line: &str) -> usize {
    match md::task_priority(line) {
        Some(tag) => md::PRIORITIES
            .iter()
            .position(|(_, hash, _)| *hash == tag)
            .unwrap_or(md::PRIORITIES.len()),
        None => md::PRIORITIES.len(),
    }
}

/// A ### -heading or `---` rule this sweep owns — stripped so it can be re-emitted only
/// where a lane is non-empty (an authored heading elsewhere is preserved as content).
fn is_scaffold(line: &str) -> bool {
    let t = line.trim();
    t == "---"
        || t.eq_ignore_ascii_case("### Done")
        || t.eq_ignore_ascii_case("### In progress")
        || md::PRIORITIES
            .iter()
            .any(|(_, _, h)| t.eq_ignore_ascii_case(h))
}

/// Rebuild the authored ## Focus body grouped by priority lane + a trailing `### Done`.
/// None when there is nothing to organize (only untagged todos and no done/scaffold —
/// the flat list is already the sorted form).
fn rebuild(body: &[&str]) -> Option<Vec<String>> {
    // one open-task bucket per lane + a trailing untagged bucket, then the done bucket
    let mut open: Vec<Vec<String>> = vec![Vec::new(); md::PRIORITIES.len() + 1];
    let mut done: Vec<String> = Vec::new();
    let mut placeholder: Option<String> = None;
    let mut had_scaffold = false;
    for l in body {
        let t = l.trim();
        if is_scaffold(l) {
            had_scaffold = true;
        } else if md::is_checked(l) {
            done.push((*l).to_string());
        } else if md::is_empty_unchecked(l) {
            placeholder = Some((*l).to_string());
        } else if md::is_task(l) {
            open[lane_of(l)].push((*l).to_string());
        } else if !t.is_empty() {
            // a stray prose line — keep it with the untagged top bucket
            open[md::PRIORITIES.len()].push((*l).to_string());
        }
    }
    let tagged = open[..md::PRIORITIES.len()].iter().any(|b| !b.is_empty());
    // Nothing to reorganize: no priority tags, no done tasks, no leftover scaffold.
    if !tagged && done.is_empty() && !had_scaffold {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    // untagged open tasks stay on top, unheaded, followed by the empty-task placeholder
    out.extend(open[md::PRIORITIES.len()].drain(..));
    out.push(placeholder.unwrap_or_else(|| "- [ ] ".to_string()));
    for (i, (_, _, heading)) in md::PRIORITIES.iter().enumerate() {
        if open[i].is_empty() {
            continue;
        }
        out.push(String::new());
        out.push((*heading).to_string());
        out.extend(open[i].drain(..));
    }
    if !done.is_empty() {
        out.push(String::new());
        out.push("---".to_string());
        out.push("### Done".to_string());
        out.extend(done);
    }
    Some(out)
}

/// Pure core: reorganize the ## Focus section of `content` by status. `None` when the
/// section is absent or already organized (no change).
fn sweep_content(content: &str) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.iter().position(|l| {
        l.strip_prefix("## ")
            .map(|r| r.trim().eq_ignore_ascii_case("Focus"))
            .unwrap_or(false)
    })?;
    // The section ends at the next H2, OR the rollup sentinel — the mirrored block after
    // it is generated, not authored, so it is left in place.
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

/// notes focus sweep — organize today's `## Focus` by status in place.
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
        // untagged stays on top; lanes descend urgent -> high -> low; done at the foot
        let untagged = focus.find("untagged one").unwrap();
        let urgent = focus.find("### Urgent").unwrap();
        let high = focus.find("### High").unwrap();
        let low = focus.find("### Low").unwrap();
        let done = focus.find("### Done").unwrap();
        assert!(untagged < urgent, "untagged above the priority lanes");
        assert!(urgent < high && high < low, "lanes ordered urgent > high > low");
        assert!(focus.find("fire").unwrap() > urgent && focus.find("fire").unwrap() < high);
        assert!(low < done, "Done is last");
        assert!(focus.find("finished it").unwrap() > done, "checked task under Done");
        assert!(out.contains("## Notes\nafter"), "later sections untouched");
    }

    #[test]
    fn checked_go_to_done_regardless_of_tag() {
        // a checked task with a priority tag lands under Done, not its priority lane
        let note = "## Focus\n- [x] shipped it #high\n- [ ] open #high\n\n## Notes\n";
        let out = sweep_content(note).unwrap();
        let done = out.find("### Done").unwrap();
        assert!(out.find("shipped it").unwrap() > done, "checked+tagged under Done");
        assert!(out.find("open").unwrap() < done, "open task stays in its High lane");
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

    #[test]
    fn no_change_when_only_untagged_todos() {
        // nothing to organize: no priority tags, no done, no scaffold
        let note = "## Focus\n- [ ] a\n- [ ] b\n- [ ] \n\n## Notes\n";
        assert!(sweep_content(note).is_none());
    }

    #[test]
    fn idempotent_on_already_swept() {
        let note = "## Focus\n- [ ] a\n- [ ] \n\n### Urgent\n- [ ] b #urgent\n\n---\n### Done\n- [x] c\n\n## Notes\n";
        // a second sweep of swept content produces no further change
        let once = sweep_content(note);
        let twice = match &once {
            Some(s) => sweep_content(s),
            None => None,
        };
        assert!(twice.is_none(), "sweep is idempotent");
    }
}
