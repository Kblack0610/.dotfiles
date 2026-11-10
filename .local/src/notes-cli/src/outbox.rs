//! `notes outbox`: one cross-org file (`<vault>/outbox.md`, its `## Outbox`) where the human
//! and agents drop work for any project. The inbox sweep (`agentctl-inbox-triage`) picks each
//! line's project and runs `notes outbox move`, which puts the line in that project's
//! `## Inbox`. The sweep then files it from there in the same pass. Each move goes in the ingest
//! record (`ingest.rs`), which the inbox status page shows.
//!
//! The section has the inbox grammar (`sheet::lines_in`), so a line is any top-level line and
//! its indented lines are its details. A `#p:<name>` word names the project: when it matches one
//! exactly the sweep moves the line with no model, and when it matches none (a typo, a shortened
//! name) `notes outbox move` exits 3 and the sweep hands the line to the model with the word as a hint.
//!
//! A pasted list is split first (`sheet::split_lists`, run by `notes outbox split` at the start of
//! each sweep): a line with two or more checkboxes directly under it becomes one line per item, so
//! each ask routes alone, and its heading's words, `#p:`, `#agent`, `#plan`, `#go` and priority go on each.
//!
//! A `#ask` word marks a question: the sweep answers it with one read-only model call and
//! `notes outbox answer` takes the line out of the outbox and writes the question and answer to
//! today's `inbox/<date>.md`, so it never reaches a project's inbox or becomes a row.
//!
//! The section is also a doc the human edits from agent-web's Daily outbox view: `notes outbox show`
//! gives its path, its items and their hash, and `notes outbox put --base <hash>` replaces them only when
//! nothing wrote the file since (compare-and-swap), so a page never clobbers a sweep's move.
//! Every write here holds one lock (`.outbox.lock` beside the file).

use crate::config::Profile;
use crate::ingest::{self, Event};
use crate::logging::Logger;
use crate::{md, project_tasks, projects, sheet};
use anyhow::{bail, Result};
use std::fs;

pub(crate) const HEADING: &str = "Outbox";

/// `move_line`'s exit when the project name matches no current project.
pub(crate) const EXIT_NO_PROJECT: i32 = 3;

fn skeleton() -> String {
    format!(
        "# Outbox\n\nOne item per line, for any project. The inbox sweep routes each to its project's inbox and files it there; what went where is on the inbox status page. `#p:<name>` names a project (a name that matches none is left to the sweep's model), `#agent` the agent board, `#plan` a plan first (held for your review when you asked for it), `#go` no review, `#ask` a quick read-only answer in the inbox.\n\n## {HEADING}\n"
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

/// The outbox's write lock, released when dropped. `add`, `move` and `put` each read, change and
/// write the whole file, so without it a page's `put` could land between a sweep's read and
/// write and one of the two writes would be lost.
fn lock(p: &Profile) -> Result<md::FileLock> {
    let dir = p
        .outbox
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));
    md::lock_file(&dir.join(".outbox.lock"))
}

/// The `## Outbox` body as the editor shows it: every line under the heading, blank lines at
/// either end dropped, trailing spaces trimmed.
fn items(content: &str) -> Vec<String> {
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, HEADING) else {
        return Vec::new();
    };
    let mut out: Vec<String> = lines[span]
        .iter()
        .map(|l| l.trim_end().to_string())
        .collect();
    while out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    let lead = out.iter().take_while(|l| l.is_empty()).count();
    out.drain(..lead);
    out
}

/// The items' compare-and-swap base (`md::fnv1a`).
fn hash(items: &[String]) -> String {
    md::fnv1a(&items.join("\n"))
}

fn show_json(p: &Profile, content: &str) -> serde_json::Value {
    let items = items(content);
    serde_json::json!({
        "path": p.outbox,
        "hash": hash(&items),
        "text": items.join("\n"),
        "waiting": sheet::lines_in(content, HEADING).len(),
    })
}

/// `notes outbox show [--json]`: the items as text, or `{path, hash, text, waiting}`, `hash` the
/// value `put --base` takes.
pub fn show(p: &Profile, json: bool) -> Result<i32> {
    let content = read(p)?;
    if json {
        println!("{}", show_json(p, &content));
    } else {
        for l in items(&content) {
            println!("{l}");
        }
    }
    Ok(0)
}

/// What a compare-and-swap put did (`notes outbox put`, `notes put`): wrote, or found the file
/// changed since `base` (nothing written).
#[derive(Debug, PartialEq)]
pub(crate) enum Put {
    Written(serde_json::Value),
    Stale(serde_json::Value),
}

pub(crate) fn put_items(p: &Profile, base: &str, text: &str) -> Result<Put> {
    let _lock = lock(p)?;
    let content = read(p)?;
    if hash(&items(&content)) != base {
        return Ok(Put::Stale(show_json(p, &content)));
    }
    let mut new: Vec<String> = text.lines().map(|l| l.trim_end().to_string()).collect();
    while new.last().is_some_and(|l| l.is_empty()) {
        new.pop();
    }
    let lead = new.iter().take_while(|l| l.is_empty()).count();
    new.drain(..lead);
    let lines: Vec<&str> = content.lines().collect();
    let out = match md::section_span(&lines, HEADING) {
        Some(span) => {
            let mut out: Vec<String> = lines[..span.start].iter().map(|l| l.to_string()).collect();
            out.extend(new.iter().cloned());
            if span.end < lines.len() {
                out.push(String::new());
                out.extend(lines[span.end..].iter().map(|l| l.to_string()));
            }
            let mut s = out.join("\n");
            s.push('\n');
            s
        }
        None => sheet::put_in(&content, HEADING, &new),
    };
    if out != content {
        md::write_atomic(&p.outbox, &out)?;
        project_tasks::inbox_changed(p);
    }
    Ok(Put::Written(show_json(p, &out)))
}

/// `notes outbox put --base <hash>`: replace the outbox's items with stdin. Exit 3, with the
/// current `show --json` printed and nothing written, when the file changed since `base`.
pub fn put(p: &Profile, log: &Logger, base: &str, text: &str) -> Result<i32> {
    match put_items(p, base, text)? {
        Put::Written(v) => {
            log.info("outbox", &format!("put {}", p.outbox.display()));
            println!("{v}");
            Ok(0)
        }
        Put::Stale(v) => {
            println!("{v}");
            eprintln!("the outbox changed since {base}; nothing written");
            Ok(3)
        }
    }
}

/// The lines waiting in the outbox, oldest first.
pub(crate) fn lines(p: &Profile) -> Result<Vec<sheet::InboxLine>> {
    Ok(sheet::lines_in(&read(p)?, HEADING))
}

/// Turn the lists waiting in the outbox into one line per ask (`sheet::split_lists`), the first
/// step of a triage sweep. Does not touch the inbox flag: the sweep that runs this reads after it.
pub fn split(p: &Profile) -> Result<i32> {
    let _lock = lock(p)?;
    let content = read(p)?;
    let (out, lists) = sheet::split_lists(&content, HEADING);
    if out != content {
        md::write_atomic(&p.outbox, &out)?;
    }
    ingest::record_splits(p, "outbox", &lists);
    Ok(0)
}

/// `notes outbox add <text>`: append `- [ ] <text>` to the outbox and wake the sweep.
pub fn add(p: &Profile, log: &Logger, text: &str) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide the item's text)");
    }
    let line = format!("- [ ] {text}");
    if append(p, log, std::slice::from_ref(&line))? {
        ingest::record(p, &Event::row("added", "outbox", "", "", &line));
    }
    println!("outbox: {line}");
    Ok(0)
}

/// Append `block`, a top-level line and its indented details, to the outbox and wake the sweep,
/// unless that line already waits there. True when it was written. `add` and
/// `notes focus ingest` both write through here, so a line from either is swept the same way.
pub(crate) fn append(p: &Profile, log: &Logger, block: &[String]) -> Result<bool> {
    let Some(line) = block.first() else {
        return Ok(false);
    };
    let _lock = lock(p)?;
    let content = read(p)?;
    if sheet::lines_in(&content, HEADING)
        .iter()
        .any(|l| &l.raw == line)
    {
        return Ok(false);
    }
    if let Some(dir) = p.outbox.parent() {
        fs::create_dir_all(dir)?;
    }
    md::write_atomic(&p.outbox, &sheet::put_in(&content, HEADING, block))?;
    project_tasks::inbox_changed(p);
    log.info("outbox", &format!("added to {}", p.outbox.display()));
    Ok(true)
}

/// `notes outbox list [--json]`: TSV `line<TAB>text`, or one JSON array of
/// `{line, raw, text, details, project, ask}`, `project` the `#p:` name when the line forces one
/// and `ask` whether it carries `#ask`.
pub fn list(p: &Profile, json: bool) -> Result<i32> {
    let lines = lines(p)?;
    if json {
        let rows: Vec<serde_json::Value> = lines
            .iter()
            .map(|l| {
                serde_json::json!({
                    "line": l.line, "raw": l.raw, "text": l.text, "details": l.details,
                    "project": md::project_tag(&l.raw), "ask": md::ask_tag(&l.raw),
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
/// the line where it is and exits 3 (`EXIT_NO_PROJECT`), so a caller can tell it from a failure.
pub fn move_line(
    p: &Profile,
    log: &Logger,
    project: &str,
    why: Option<&str>,
    raw: &str,
) -> Result<i32> {
    let _lock = lock(p)?;
    // The project sheet is a ptask sheet, so its write holds the ptask lock too (always taken
    // after the outbox's: no ptask verb takes the outbox lock, so the order cannot invert).
    let _sheet = project_tasks::lock(p)?;
    let content = read(p)?;
    let Some((rest, line)) = sheet::take_in(&content, HEADING, |l| l.raw == raw) else {
        eprintln!("no outbox line is '{raw}'");
        return Ok(1);
    };
    let dir = match projects::project_dir(p, project) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}; the line stays in the outbox");
            return Ok(EXIT_NO_PROJECT);
        }
    };
    let mut block = vec![md::without_project_tag(&line.raw)];
    block.extend(md::detail_lines("", &line.details));
    let sheet = project_tasks::inbox_put(p, &dir, project, &block)?;
    md::write_atomic(&p.outbox, &rest)?;
    let text = md::without_project_tag(&line.text);
    ingest::record(
        p,
        &Event {
            why: ingest::set(why),
            ..Event::new("moved", "outbox", project, &text)
        },
    );
    log.info("outbox", &format!("moved to {}", sheet.display()));
    // The last line is the line as the inbox now holds it (its `#p:` word is gone), which the
    // sweep needs to file it from there.
    println!("moved {text}\n  -> {project} inbox\n  line: {}", block[0]);
    Ok(0)
}

/// `notes outbox answer -- <raw>`, the answer on stdin: take the outbox line that is `raw` byte
/// for byte out of the outbox and write it, with the answer, to today's `inbox/<date>.md` as
/// `- HH:MM ask: <question> - <answer's first line>`, the answer's other lines indented under it.
/// The capture is written first, so a failed second write leaves the question in both places
/// (answered twice, never lost). The line is not moved to a project and files no row.
pub fn answer(p: &Profile, log: &Logger, raw: &str, answer: &str) -> Result<i32> {
    let answer = answer.trim();
    if answer.is_empty() {
        bail!("nothing to answer with (give the answer on stdin)");
    }
    let _lock = lock(p)?;
    let content = read(p)?;
    let Some((rest, line)) = sheet::take_in(&content, HEADING, |l| l.raw == raw) else {
        eprintln!("no outbox line is '{raw}'");
        return Ok(1);
    };
    let question = md::without_ask_tag(&md::without_project_tag(&line.text));
    let mut rows = answer.lines();
    let mut body = format!(
        "ask: {question} - {}",
        rows.next().unwrap_or_default().trim()
    );
    for r in rows {
        // A continuation that begins `- ` would read as a capture of its own.
        let r = r.trim();
        let r = r
            .strip_prefix("- ")
            .map_or(r.to_string(), |t| format!("* {t}"));
        body.push_str(&format!("\n  {r}"));
    }
    let file = crate::inbox::append(p, &body)?;
    md::write_atomic(&p.outbox, &rest)?;
    ingest::record(p, &Event::new("answered", "outbox", "inbox", &question));
    log.info("outbox", &format!("answered in {}", file.display()));
    println!("answered {question}\n  -> {}", file.display());
    Ok(0)
}

/// `notes outbox drop -- <raw>`: take the outbox line that is `raw` byte for byte out of the
/// outbox and file nothing, recorded as `dropped`. The person's own answer to "which project is
/// this about?" is the only caller: a line nobody asked about is never dropped.
pub fn drop_line(p: &Profile, log: &Logger, raw: &str) -> Result<i32> {
    let _lock = lock(p)?;
    let content = read(p)?;
    let Some((rest, line)) = sheet::take_in(&content, HEADING, |l| l.raw == raw) else {
        eprintln!("no outbox line is '{raw}'");
        return Ok(1);
    };
    md::write_atomic(&p.outbox, &rest)?;
    let text = md::without_project_tag(&line.text);
    ingest::record(p, &Event::new("dropped", "outbox", "", &text));
    log.info("outbox", "dropped a line");
    println!("dropped {text}");
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
    fn an_answer_takes_the_question_out_and_writes_both_to_todays_inbox() {
        let (root, p, log) = vault("answer");
        fs::write(
            &p.outbox,
            format!(
                "{}- [ ] #ask is my mac ok? #p:demo\n- [ ] stays\n",
                skeleton()
            ),
        )
        .unwrap();
        assert!(md::ask_tag("- [ ] #ask is my mac ok? #p:demo"));
        assert!(md::ask_tag("- [ ] is the nas up? #ask #p:demo"));
        assert!(!md::ask_tag("- [ ] document the #ask flow in the README"));
        assert_eq!(
            answer(
                &p,
                &log,
                "- [ ] #ask is my mac ok? #p:demo",
                "Yes, up 3 days.\n- load 0.2\n"
            )
            .unwrap(),
            0
        );
        let left: Vec<String> = lines(&p).unwrap().into_iter().map(|l| l.text).collect();
        assert_eq!(left, ["stays"]);
        let day = chrono::Local::now().format("%Y-%m-%d").to_string();
        let note = fs::read_to_string(p.inbox.join(format!("{day}.md"))).unwrap();
        assert!(
            note.contains("ask: is my mac ok? - Yes, up 3 days.\n  * load 0.2\n"),
            "{note}"
        );
        let sheet = fs::read_to_string(root.join("lab/projects/current/demo/README.md")).unwrap();
        assert!(!sheet.contains("mac"), "an ask files nothing: {sheet}");
        let ev = ingest::on_day(&p, &day);
        assert_eq!(
            (
                ev[0].action.as_str(),
                ev[0].from.as_str(),
                ev[0].text.as_str()
            ),
            ("answered", "outbox", "is my mac ok?")
        );
        // A line that is no longer there is refused and nothing is written.
        assert_eq!(answer(&p, &log, "- [ ] gone", "x").unwrap(), 1);
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
            move_line(
                &p,
                &log,
                "demo",
                Some("#p: tag"),
                "- [ ] loading screen options #p:demo"
            )
            .unwrap(),
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
        assert_eq!(ev[0].why.as_deref(), Some("#p: tag"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unknown_project_leaves_the_line_in_the_outbox() {
        let (root, p, log) = vault("unknown");
        add(&p, &log, "a thing").unwrap();
        let before = fs::read_to_string(&p.outbox).unwrap();
        assert_eq!(
            move_line(&p, &log, "no-such-project", None, "- [ ] a thing").unwrap(),
            EXIT_NO_PROJECT
        );
        assert_eq!(fs::read_to_string(&p.outbox).unwrap(), before);
        assert_eq!(move_line(&p, &log, "demo", None, "- [ ] other").unwrap(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    fn base(p: &Profile) -> String {
        show_json(p, &read(p).unwrap())["hash"]
            .as_str()
            .unwrap()
            .to_string()
    }

    #[test]
    fn put_on_the_base_it_read_replaces_the_items_and_keeps_the_header() {
        let (root, p, log) = vault("put");
        add(&p, &log, "one").unwrap();
        add(&p, &log, "two").unwrap();
        let flag = crate::project_tasks::inbox_flag(&p);
        let _ = fs::remove_file(&flag);
        let got = put_items(&p, &base(&p), "- [ ] one\nthree, typed in the page\n\n").unwrap();
        let Put::Written(v) = got else {
            panic!("stale: {got:?}")
        };
        let content = fs::read_to_string(&p.outbox).unwrap();
        assert!(
            content.starts_with("# Outbox\n\nOne item per line"),
            "{content}"
        );
        assert!(
            content.ends_with("## Outbox\n- [ ] one\nthree, typed in the page\n"),
            "{content}"
        );
        let raws: Vec<String> = lines(&p).unwrap().into_iter().map(|l| l.raw).collect();
        assert_eq!(raws, ["- [ ] one", "three, typed in the page"]);
        assert_eq!(v["text"], "- [ ] one\nthree, typed in the page");
        assert_eq!(
            v["hash"],
            base(&p).as_str(),
            "the answer names the file as written"
        );
        assert!(flag.exists(), "a put wakes the sweep");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn put_on_a_stale_base_writes_nothing_and_returns_the_file_as_it_is() {
        let (root, p, log) = vault("stale");
        add(&p, &log, "one").unwrap();
        let read_by_page = base(&p);
        // The sweep moves the line while the page is typing.
        assert_eq!(move_line(&p, &log, "demo", None, "- [ ] one").unwrap(), 0);
        let before = fs::read(&p.outbox).unwrap();
        let got = put_items(&p, &read_by_page, "- [ ] one\ntwo").unwrap();
        let Put::Stale(v) = got else {
            panic!("written: {got:?}")
        };
        assert_eq!(fs::read(&p.outbox).unwrap(), before, "byte-identical");
        assert_eq!(v["text"], "");
        assert_eq!(v["waiting"], 0);
        assert_eq!(put(&p, &log, &read_by_page, "x").unwrap(), 3);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn put_keeps_a_section_below_the_outbox_and_makes_a_missing_file() {
        let (root, p, _log) = vault("below");
        let empty = hash(&items(&skeleton()));
        let Put::Written(_) = put_items(&p, &empty, "first").unwrap() else {
            panic!()
        };
        assert_eq!(lines(&p).unwrap()[0].raw, "first");
        fs::write(
            &p.outbox,
            "# Outbox\n\n## Outbox\n- a\n\n## Notes\nkeep me\n",
        )
        .unwrap();
        let Put::Written(_) = put_items(&p, &base(&p), "- b").unwrap() else {
            panic!()
        };
        assert_eq!(
            fs::read_to_string(&p.outbox).unwrap(),
            "# Outbox\n\n## Outbox\n- b\n\n## Notes\nkeep me\n"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn drop_takes_only_the_named_line_out_and_records_it() {
        let (root, p, log) = vault("drop");
        add(&p, &log, "keep me").unwrap();
        add(&p, &log, "drop me #p:demo").unwrap();
        assert_eq!(drop_line(&p, &log, "- [ ] drop me #p:demo").unwrap(), 0);
        let left: Vec<String> = lines(&p).unwrap().into_iter().map(|l| l.text).collect();
        assert_eq!(left, vec!["keep me".to_string()]);
        let rec = fs::read_to_string(ingest::path(&p)).unwrap_or_default();
        assert!(rec.contains("\"dropped\"") && rec.contains("drop me"), "{rec}");
        // A line that is not there drops nothing (negative control).
        assert_eq!(drop_line(&p, &log, "- [ ] drop me #p:demo").unwrap(), 1);
        assert_eq!(lines(&p).unwrap().len(), 1);
        let _ = fs::remove_dir_all(&root);
    }
}
