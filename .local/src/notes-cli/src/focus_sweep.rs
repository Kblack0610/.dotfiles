//! `notes focus sweep` — reorganize today's `## Focus` by task status, so a task moves
//! between lanes as its checkbox is cycled: todo (`[ ]`) on top, in-progress (`[/]`)
//! under `### In progress`, done (`[x]`) under `--- / ### Done`.
//!
//! This mirrors the nvim buffer sweep (markdown.lua `rebuild_focus_body`) so that
//! marking a task done from the cockpit organizes the note exactly like cycling its
//! status in the editor does — the note stays grouped by status no matter which surface
//! you touch. Only the AUTHORED region is reorganized: a rollup mirror (everything from
//! `md::ROLLUP_START` on) is left untouched at the end of the section.
//!
//! Lives in its own module to stay clear of a concurrent `focus.rs` refactor.

use crate::config::Profile;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use std::fs;

fn is_inprogress(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("- [/]") || t.starts_with("- [-]")
}

/// Rebuild the authored `## Focus` body grouped by status. `None` when there is nothing
/// to organize (no in-progress / done task and no leftover scaffold to collapse).
fn rebuild(body: &[&str]) -> Option<Vec<String>> {
    let (mut todo, mut inprog, mut done): (Vec<String>, Vec<String>, Vec<String>) =
        (Vec::new(), Vec::new(), Vec::new());
    let mut placeholder: Option<String> = None;
    let mut had_scaffold = false;
    for l in body {
        let t = l.trim();
        if t.eq_ignore_ascii_case("### Done")
            || t.eq_ignore_ascii_case("### In progress")
            || t == "---"
        {
            had_scaffold = true;
        } else if md::is_checked(l) {
            done.push((*l).to_string());
        } else if is_inprogress(l) {
            inprog.push((*l).to_string());
        } else if md::is_empty_unchecked(l) {
            placeholder = Some((*l).to_string());
        } else if !t.is_empty() {
            todo.push((*l).to_string());
        }
    }
    if inprog.is_empty() && done.is_empty() && !had_scaffold {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    out.extend(todo);
    out.push(placeholder.unwrap_or_else(|| "- [ ] ".to_string()));
    if !inprog.is_empty() {
        out.push(String::new());
        out.push("### In progress".to_string());
        out.extend(inprog);
    }
    if !done.is_empty() {
        out.push(String::new());
        out.push("---".to_string());
        out.push("### Done".to_string());
        out.extend(done);
    }
    Some(out)
}

/// Pure core: reorganize the `## Focus` section of `content` by status. `None` when the
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

/// `notes focus start <query>` — toggle the first matching authored `## Focus` task
/// between `[ ]` (todo) and `[/]` (in progress). Pair with a sweep to move it into the
/// right lane. Only the authored region is scanned (stops at the next H2 / rollup
/// sentinel), matching by the same normalised key as `done`.
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

/// `notes focus sweep` — organize today's `## Focus` by status in place.
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
    fn groups_todo_inprogress_done_into_lanes() {
        let note = "\
## Focus
- [ ] todo one
- [x] finished it
- [/] doing this
- [ ] todo two
- [ ]

## Notes
after
";
        let out = sweep_content(note).unwrap();
        // todo on top (in original order), placeholder kept, then In progress, then Done
        let focus = out.split("## Notes").next().unwrap();
        let todo_pos = focus.find("todo one").unwrap();
        let ip_hdr = focus.find("### In progress").unwrap();
        let ip_task = focus.find("doing this").unwrap();
        let done_hdr = focus.find("### Done").unwrap();
        let done_task = focus.find("finished it").unwrap();
        assert!(todo_pos < ip_hdr, "todo above In progress");
        assert!(ip_hdr < ip_task && ip_task < done_hdr, "in-progress task under its header");
        assert!(done_hdr < done_task, "done task under Done header");
        assert!(out.contains("## Notes\nafter"), "later sections untouched");
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
    fn no_change_when_only_todos() {
        // nothing to organize: no in-progress, no done, no scaffold
        let note = "## Focus\n- [ ] a\n- [ ] b\n- [ ] \n\n## Notes\n";
        assert!(sweep_content(note).is_none());
    }

    #[test]
    fn idempotent_on_already_swept() {
        let note = "## Focus\n- [ ] a\n- [ ] \n\n### In progress\n- [/] b\n\n---\n### Done\n- [x] c\n\n## Notes\n";
        // a second sweep of swept content produces no further change
        let once = sweep_content(note);
        let twice = match &once {
            Some(s) => sweep_content(s),
            None => None,
        };
        assert!(twice.is_none(), "sweep is idempotent");
    }
}
