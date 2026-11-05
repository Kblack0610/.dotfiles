//! `notes outbox`: one cross-org file (`<vault>/outbox.md`, its `## Outbox`) where the human
//! and agents drop work for any project. The inbox sweep (`agentctl-inbox-triage`) picks each
//! line's project and runs `notes outbox move`, which puts the line in that project's
//! `## Inbox`. The sweep then files it from there in the same pass. Each move goes in the ingest
//! record (`ingest.rs`), which the inbox status page shows.
//!
//! The section has the inbox grammar (`sheet::lines_in`), so a line is any top-level line and
//! its indented lines are its details. A `#p:<name>` word forces the project.

use crate::config::Profile;
use crate::ingest::{self, Event};
use crate::logging::Logger;
use crate::{md, project_tasks, projects, sheet};
use anyhow::{bail, Result};
use std::fs;

pub(crate) const HEADING: &str = "Outbox";

fn skeleton() -> String {
    format!(
        "# Outbox\n\nOne item per line, for any project. The inbox sweep routes each to its project's inbox and files it there; what went where is on the inbox status page. `#p:<name>` forces a project, `#agent` the agent board, `#plan` a planning pass.\n\n## {HEADING}\n"
    )
}

fn read(p: &Profile) -> Result<String> {
    match fs::read_to_string(&p.outbox) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(skeleton()),
        Err(e) => Err(e.into()),
    }
}

/// Write the skeleton when the outbox does not exist yet, so a file opened from the daily note's
/// link already has its `## Outbox` and a line typed under it is seen by the sweep.
pub(crate) fn ensure(p: &Profile) -> Result<()> {
    if p.outbox.exists() {
        return Ok(());
    }
    if let Some(dir) = p.outbox.parent() {
        fs::create_dir_all(dir)?;
    }
    md::write_atomic(&p.outbox, &skeleton())?;
    Ok(())
}

/// The lines waiting in the outbox, oldest first.
pub(crate) fn lines(p: &Profile) -> Result<Vec<sheet::InboxLine>> {
    Ok(sheet::lines_in(&read(p)?, HEADING))
}

/// `notes outbox add <text>`: append `- [ ] <text>` to the outbox and wake the sweep.
pub fn add(p: &Profile, log: &Logger, text: &str) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide the item's text)");
    }
    let content = read(p)?;
    let line = format!("- [ ] {text}");
    if !sheet::lines_in(&content, HEADING)
        .iter()
        .any(|l| l.raw == line)
    {
        if let Some(dir) = p.outbox.parent() {
            fs::create_dir_all(dir)?;
        }
        md::write_atomic(
            &p.outbox,
            &sheet::put_in(&content, HEADING, std::slice::from_ref(&line)),
        )?;
        project_tasks::inbox_changed(p);
        log.info("outbox", &format!("added to {}", p.outbox.display()));
    }
    println!("outbox: {line}");
    Ok(0)
}

/// `notes outbox list [--json]`: TSV `line<TAB>text`, or one JSON array of
/// `{line, raw, text, details, project}`, `project` the `#p:` name when the line forces one.
pub fn list(p: &Profile, json: bool) -> Result<i32> {
    let lines = lines(p)?;
    if json {
        let rows: Vec<serde_json::Value> = lines
            .iter()
            .map(|l| {
                serde_json::json!({
                    "line": l.line, "raw": l.raw, "text": l.text, "details": l.details,
                    "project": md::project_tag(&l.raw),
                })
            })
            .collect();
        println!("{}", serde_json::Value::Array(rows));
        return Ok(0);
    }
    for l in &lines {
        println!("{}\t{}", l.line, l.text);
    }
    Ok(0)
}

/// `notes outbox move --project <p> -- <raw>`: take the outbox line that is `raw` byte for byte
/// and put it, its `#p:` word taken off, at the end of `<p>`'s `## Inbox`. The inbox is written
/// first, so a failed second write leaves the line in both places (seen twice, and
/// `inbox_put` does not write it twice) and never in neither. A name that is no project leaves
/// the line where it is and exits 1.
pub fn move_line(p: &Profile, log: &Logger, project: &str, raw: &str) -> Result<i32> {
    let content = read(p)?;
    let Some((rest, line)) = sheet::take_in(&content, HEADING, |l| l.raw == raw) else {
        eprintln!("no outbox line is '{raw}'");
        return Ok(1);
    };
    let dir = match projects::project_dir(p, project) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}; the line stays in the outbox");
            return Ok(1);
        }
    };
    let mut block = vec![md::without_project_tag(&line.raw)];
    block.extend(md::detail_lines("", &line.details));
    let sheet = project_tasks::inbox_put(p, &dir, project, &block)?;
    md::write_atomic(&p.outbox, &rest)?;
    let text = md::without_project_tag(&line.text);
    ingest::record(p, &Event::new("moved", "outbox", project, &text));
    log.info("outbox", &format!("moved to {}", sheet.display()));
    println!("moved {text}\n  -> {project} inbox");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A vault with one project, `demo`, and its human sheet.
    fn vault(tag: &str) -> (std::path::PathBuf, Profile, Logger) {
        let root = std::env::temp_dir().join(format!("outbox-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut p = crate::config::test_profile(&root.to_string_lossy());
        let projects = root.join("lab/projects/current");
        let dir = projects.join("demo");
        fs::create_dir_all(&dir).unwrap();
        let index = root.join("lab/projects/index.md");
        fs::write(
            &index,
            "## Current\n- [[lab/projects/current/demo/summary|demo]]\n",
        )
        .unwrap();
        fs::write(dir.join("summary.md"), "# demo\n").unwrap();
        fs::write(dir.join("README.md"), "# demo\n\n## Tasks\n- [ ] row\n").unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);
        (root, p, log)
    }

    #[test]
    fn add_makes_the_file_once_and_wakes_the_sweep() {
        let (root, p, log) = vault("add");
        add(&p, &log, "the gun shot is late").unwrap();
        add(&p, &log, "the gun shot is late").unwrap();
        add(&p, &log, "loading screen options #p:demo").unwrap();
        let got = lines(&p).unwrap();
        let texts: Vec<&str> = got.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(
            texts,
            ["the gun shot is late", "loading screen options #p:demo"]
        );
        assert!(fs::read_to_string(&p.outbox)
            .unwrap()
            .starts_with("# Outbox\n"));
        assert!(
            project_tasks::inbox_flag(&p).exists(),
            "an add must wake the sweep"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn ensure_makes_a_file_a_typed_line_is_read_from_and_keeps_an_existing_one() {
        let (root, p, _log) = vault("ensure");
        ensure(&p).unwrap();
        let mut s = fs::read_to_string(&p.outbox).unwrap();
        s.push_str("- typed by hand\n");
        fs::write(&p.outbox, &s).unwrap();
        ensure(&p).unwrap();
        let got = lines(&p).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].text, "typed by hand");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_move_puts_the_line_in_the_inbox_without_its_tag_and_records_it() {
        let (root, p, log) = vault("move");
        fs::write(
            &p.outbox,
            format!(
                "{}- [ ] loading screen options #p:demo\n  three kinds\n- [ ] stays\n",
                skeleton()
            ),
        )
        .unwrap();
        assert_eq!(
            move_line(&p, &log, "demo", "- [ ] loading screen options #p:demo").unwrap(),
            0
        );
        let sheet = fs::read_to_string(root.join("lab/projects/current/demo/README.md")).unwrap();
        assert!(
            sheet.contains("## Inbox\n- [ ] loading screen options\n  three kinds\n"),
            "{sheet}"
        );
        let left: Vec<String> = lines(&p).unwrap().into_iter().map(|l| l.text).collect();
        assert_eq!(left, ["stays"]);
        let ev = ingest::on_day(&p, &chrono::Local::now().format("%Y-%m-%d").to_string());
        assert_eq!(
            (
                ev[0].action.as_str(),
                ev[0].from.as_str(),
                ev[0].to.as_str(),
                ev[0].text.as_str()
            ),
            ("moved", "outbox", "demo", "loading screen options")
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unknown_project_leaves_the_line_in_the_outbox() {
        let (root, p, log) = vault("unknown");
        add(&p, &log, "a thing").unwrap();
        let before = fs::read_to_string(&p.outbox).unwrap();
        assert_eq!(
            move_line(&p, &log, "no-such-project", "- [ ] a thing").unwrap(),
            1
        );
        assert_eq!(fs::read_to_string(&p.outbox).unwrap(), before);
        assert_eq!(move_line(&p, &log, "demo", "- [ ] other").unwrap(), 1);
        let _ = fs::remove_dir_all(&root);
    }
}
