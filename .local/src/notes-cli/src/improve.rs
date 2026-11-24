//! `notes improve <project> -- "<text>"`: an agent's nice-to-have, kept where it can be pulled
//! from and never filed as a board row. The triager's `improvement` verdict (the priority rubric
//! in `agentctl-inbox-triage`) is the caller. The line goes to the project's `improvements.md`,
//! created from `templates/improvements.md` on the first write, and into the ingest record as
//! `improvement`, like every other write of intake.
//!
//! `ideas.md` is the person's own file: this writer targets `improvements.md` only
//! ([`IMPROVEMENTS`]) and refuses any other name ([`append`]), so no agent path can write it.
//! Promoting a line to work stays `notes ptask <project> --agent add`.

use crate::config::Profile;
use crate::ingest::{self, Event};
use crate::logging::Logger;
use crate::md;
use crate::projects;
use anyhow::{bail, Context, Result};
use std::fs;
use std::io::Write;
use std::path::Path;

/// The one file this writer may touch, beside the person's `ideas.md`.
pub const IMPROVEMENTS: &str = "improvements.md";

/// A fresh `improvements.md`.
fn template(name: &str) -> String {
    include_str!("../templates/improvements.md").replace("{name}", name)
}

/// `text` on one line: whitespace runs collapsed, the intake bookkeeping tags (`#agent`,
/// `#from/<writer>`, priority, size, routing and plan words) dropped: the file is read by a
/// person, and a line copied from it into `ptask add` must not carry a stale route or plan.
fn one_line(text: &str) -> String {
    const WORDS: [&str; 4] = ["#agent", "#plan", "#go", "#requested"];
    const PREFIXES: [&str; 5] = ["#from/", "#size/", "#pts/", "#of/", "#p:"];
    text.split_whitespace()
        .filter(|w| {
            let w = w.to_ascii_lowercase();
            !(WORDS.contains(&w.as_str())
                || md::PRIORITIES.iter().any(|(_, tag, _)| w == *tag)
                || PREFIXES.iter().any(|p| w.starts_with(p)))
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Append `- <text>` to `file` in `dir`, the header first when the file is new. `Ok(false)`
/// when the line is already there, so a retried write adds nothing. Any `file` but
/// [`IMPROVEMENTS`] is refused: the person's `ideas.md` is never written from here.
fn append(dir: &Path, name: &str, file: &str, text: &str, day: &str) -> Result<bool> {
    if file != IMPROVEMENTS {
        bail!("{file} is not written by notes improve; only {IMPROVEMENTS} is");
    }
    let path = dir.join(file);
    // Only a missing file is empty: an unreadable one must not get a second header.
    let have = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    let line = format!("- {text}");
    if have
        .lines()
        .any(|l| l == line || l.strip_prefix("- ").is_some_and(|r| strip_stamp(r) == text))
    {
        return Ok(false);
    }
    let mut out = if have.is_empty() {
        format!("{}\n", template(name).trim_end())
    } else if have.ends_with('\n') {
        String::new()
    } else {
        "\n".into()
    };
    if have.is_empty() {
        out.push('\n');
    }
    out.push_str(&format!("{line} ({day})\n"));
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    // One write, so two sessions appending at once cannot interleave within a line.
    f.write_all(out.as_bytes())?;
    Ok(true)
}

/// A line's text without its trailing ` (YYYY-MM-DD)` stamp.
fn strip_stamp(line: &str) -> &str {
    match line.rsplit_once(" (") {
        Some((head, tail))
            if tail.len() == 11
                && tail.ends_with(')')
                && tail[..10].chars().all(|c| c.is_ascii_digit() || c == '-') =>
        {
            head
        }
        _ => line,
    }
}

/// `notes improve <project> [--why W] -- <text>`.
#[derive(clap::Args)]
pub struct Args {
    /// The project the line is about
    project: String,
    /// Why it is an improvement, kept on its `improvement` event (`notes log` shows it)
    #[arg(long, value_name = "WHY")]
    why: Option<String>,
    #[arg(required = true, num_args = 1..)]
    text: Vec<String>,
}

/// `notes improve`: print `improved <project>: <text>` and record it. Exit 1 on an empty text; a
/// project that is not one is an error naming it.
pub fn run(p: &Profile, log: &Logger, a: Args) -> Result<i32> {
    save(p, log, &a.project, a.why.as_deref(), &a.text.join(" "))
}

fn save(p: &Profile, log: &Logger, project: &str, why: Option<&str>, text: &str) -> Result<i32> {
    let text = one_line(text);
    if text.is_empty() {
        eprintln!("nothing to keep: the text is empty");
        return Ok(1);
    }
    let dir = projects::project_dir(p, project)?;
    let day = chrono::Local::now().format("%Y-%m-%d").to_string();
    let added = append(&dir, project, IMPROVEMENTS, &text, &day)?;
    // A repeat (a retry after a failed removal) is no second improvement in the record.
    if added {
        let mut ev = Event::new("improvement", "", project, &text);
        ev.why = ingest::set(why);
        ingest::record(p, &ev);
        log.info("improve", &format!("{project}: kept in {IMPROVEMENTS}"));
    }
    println!(
        "{} {project}: {text}",
        if added {
            "improved"
        } else {
            "already in improvements.md,"
        }
    );
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(tag: &str) -> (std::path::PathBuf, Profile, Logger) {
        let root = std::env::temp_dir().join(format!("improve-{tag}-{}", std::process::id()));
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
        fs::write(dir.join("ideas.md"), "# demo - ideas\n\nmine, by hand\n").unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);
        (root, p, log)
    }

    #[test]
    fn the_first_write_makes_the_file_from_the_template_and_ideas_md_is_untouched() {
        let (root, p, log) = project("first");
        let dir = root.join("lab/projects/current/demo");
        let before = fs::read(dir.join("ideas.md")).unwrap();
        assert_eq!(
            save(
                &p,
                &log,
                "demo",
                Some("polish"),
                "a nicer empty state #agent #from/sess1 #low #normal"
            )
            .unwrap(),
            0
        );
        let got = fs::read_to_string(dir.join(IMPROVEMENTS)).unwrap();
        assert!(
            got.starts_with("# demo - improvements\n\nNice-to-haves agents found"),
            "{got}"
        );
        assert!(got.contains("\n- a nicer empty state ("), "{got}");
        assert!(
            !got.contains("#from/") && !got.contains("#low") && !got.contains("#normal"),
            "{got}"
        );
        assert_eq!(
            fs::read(dir.join("ideas.md")).unwrap(),
            before,
            "ideas.md is the person's"
        );
        let rec = fs::read_to_string(ingest::path(&p)).unwrap();
        assert!(
            rec.contains("\"action\":\"improvement\"")
                && rec.contains("\"to\":\"demo\"")
                && rec.contains("a nicer empty state"),
            "{rec}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_second_line_appends_and_a_repeat_adds_nothing() {
        let (root, p, log) = project("repeat");
        let f = root.join("lab/projects/current/demo").join(IMPROVEMENTS);
        save(&p, &log, "demo", None, "first nicety").unwrap();
        save(&p, &log, "demo", None, "second nicety").unwrap();
        save(&p, &log, "demo", None, "first   nicety").unwrap();
        let got = fs::read_to_string(&f).unwrap();
        assert_eq!(got.matches("first nicety").count(), 1, "{got}");
        assert_eq!(got.matches("# demo - improvements").count(), 1, "{got}");
        assert!(got.contains("second nicety"), "{got}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_repeat_records_one_event_and_routing_tags_are_stripped() {
        let (root, p, log) = project("event");
        save(
            &p,
            &log,
            "demo",
            None,
            "nicety #size/s #pts/1 #p:demo #plan #go #of/x",
        )
        .unwrap();
        save(&p, &log, "demo", None, "nicety").unwrap();
        let rec = fs::read_to_string(ingest::path(&p)).unwrap();
        assert_eq!(
            rec.matches("\"action\":\"improvement\"").count(),
            1,
            "{rec}"
        );
        let got =
            fs::read_to_string(root.join("lab/projects/current/demo").join(IMPROVEMENTS)).unwrap();
        assert!(got.contains("\n- nicety ("), "{got}");
        assert!(
            !got.contains("#size") && !got.contains("#plan") && !got.contains("#go"),
            "{got}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unreadable_file_is_an_error_not_an_empty_one() {
        let dir = std::env::temp_dir().join(format!("improve-unread-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        // A directory where the file should be: reading it fails with something but NotFound.
        fs::create_dir_all(dir.join(IMPROVEMENTS)).unwrap();
        assert!(append(&dir, "demo", IMPROVEMENTS, "x", "2026-11-19").is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn any_file_but_improvements_md_is_refused() {
        let dir = std::env::temp_dir().join(format!("improve-guard-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("ideas.md"), "mine\n").unwrap();
        for f in ["ideas.md", "../ideas.md", "summary.md"] {
            assert!(append(&dir, "demo", f, "x", "2026-11-19").is_err(), "{f}");
        }
        assert_eq!(fs::read_to_string(dir.join("ideas.md")).unwrap(), "mine\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_text_and_an_unknown_project_write_nothing() {
        let (root, p, log) = project("bad");
        assert_eq!(save(&p, &log, "demo", None, "  #agent  #low ").unwrap(), 1);
        assert!(save(&p, &log, "nosuch", None, "x").is_err());
        assert!(!root
            .join("lab/projects/current/demo")
            .join(IMPROVEMENTS)
            .exists());
        assert!(!ingest::path(&p).exists());
        let _ = fs::remove_dir_all(&root);
    }
}
