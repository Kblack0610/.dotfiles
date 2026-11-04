//! `<project>/playtest.md` - the things to play and tick off, beside the project sheet.
//!
//! Its own file because a playtest row is a different kind of row: one concrete scene or mode
//! to play and what to look for. Kept as sheet rows they grew into 3 KB catch-alls. The file is
//! only worth having while every row stays that small, so `add` refuses anything that is not
//! one short ASCII line (a multi-part playtest is several rows), and `notes ptask <p>
//! --playtest` is the only writer: agents never hand-edit it.
//!
//! Rows sit under `## <game>` headings and are read through the same `md` section helpers and
//! open-task predicate as the sheet, so `list`, `done`, `rm` and the board count agree.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use crate::project_tasks;
use crate::projects;
use anyhow::{bail, Result};
use std::fs;
use std::path::{Path, PathBuf};

/// Longest check text `add` accepts. Longer is a catch-all in the making.
const MAX_CHARS: usize = 200;

/// The heading a check goes under when `--game` is not given.
const DEFAULT_GAME: &str = "General";

/// A `ptask --playtest` verb, already narrowed by `main` to the four this file supports.
pub enum Op {
    List,
    Add {
        game: Option<String>,
        pr: Option<u64>,
        text: String,
    },
    Done {
        proof: Option<String>,
        unverified: Option<String>,
        query: String,
    },
    Rm {
        query: String,
    },
}

/// A project's playtest file: `<project>/playtest.md`, beside the `README.md` sheet.
pub fn path(dir: &Path) -> PathBuf {
    dir.join("playtest.md")
}

/// `notes ptask <name> --playtest <verb>`.
pub fn run(p: &Profile, log: &Logger, name: &str, op: Op) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
    let project = dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(name)
        .to_string();
    match op {
        Op::List => {
            for row in list_rows(&path(&dir)) {
                println!("{row}");
            }
            Ok(0)
        }
        Op::Add { game, pr, text } => add_in(log, &dir, &project, game.as_deref(), pr, &text),
        Op::Done {
            proof,
            unverified,
            query,
        } => done_in(
            log,
            &dir,
            &project,
            &query,
            proof.as_deref(),
            unverified.as_deref(),
        ),
        Op::Rm { query } => edit_in(log, &dir, &project, &query, "removed", |_| None),
    }
}

/// The head a new playtest.md starts with: the title and the one rule every row follows.
fn header(project: &str) -> String {
    format!(
        "# Playtest\n\nOne row is one thing to play and check off: the scene or mode, and what \
         to look for. Written with `notes ptask {project} --playtest add`.\n"
    )
}

/// `text` trimmed, or the reason it cannot be one row. `what` names the field in the error.
fn checked<'a>(what: &str, text: &'a str) -> Result<&'a str> {
    let why = if text.trim().is_empty() {
        "it is empty"
    } else if text.contains(['\n', '\r']) {
        "it is more than one line"
    } else if text.trim().chars().count() > MAX_CHARS {
        "it is over 200 characters"
    } else if !text.is_ascii() {
        "it is not plain ASCII"
    } else {
        return Ok(text.trim());
    };
    bail!(
        "playtest {what} refused: {why}. One row is one thing to play and check off; a \
         multi-part playtest is several rows, one `--playtest add` each."
    )
}

/// The `## ` headings of the file, first occurrence of each name, in file order. Every reader
/// walks these through `md::section_numbered`, so a duplicated heading reads the way
/// `md::section_span` resolves it: the first one wins, for every verb alike.
fn games(content: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for l in content.lines() {
        if let Some(h) = l.strip_prefix("## ") {
            let h = h.trim();
            if !out.iter().any(|g| g.eq_ignore_ascii_case(h)) {
                out.push(h.to_string());
            }
        }
    }
    out
}

/// Every open row as `(1-based line, game, line text)`.
fn open_rows(content: &str) -> Vec<(usize, String, &str)> {
    games(content)
        .into_iter()
        .flat_map(|g| {
            md::section_numbered(content, &g)
                .into_iter()
                .filter(|(_, l)| md::is_open_task(l))
                .map(move |(n, l)| (n, g.clone(), l))
        })
        .collect()
}

/// How many checks in `dir`'s playtest.md are still open; 0 when there is no file.
pub(crate) fn open_count(dir: &Path) -> usize {
    fs::read_to_string(path(dir))
        .map(|c| open_rows(&c).len())
        .unwrap_or(0)
}

/// `list` rows as TSV: `path<TAB>line<TAB>game<TAB>text`. Empty when there is no file.
fn list_rows(file: &Path) -> Vec<String> {
    let Ok(content) = fs::read_to_string(file) else {
        return Vec::new();
    };
    open_rows(&content)
        .into_iter()
        .map(|(n, g, l)| format!("{}\t{n}\t{g}\t{}", file.display(), md::task_text(l)))
        .collect()
}

/// `content` with `row` appended at the foot of `## game`, opening that heading at the end of
/// the file when it is absent. Heading match is `md::section_span`'s, so case-insensitive.
fn insert_row(content: &str, game: &str, row: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, game) else {
        return format!("{}\n\n## {game}\n{row}\n", content.trim_end());
    };
    let at = span
        .clone()
        .rev()
        .find(|&i| !lines[i].trim().is_empty())
        .map_or(span.start, |i| i + 1);
    let mut out: Vec<&str> = lines;
    out.insert(at, row);
    format!("{}\n", out.join("\n"))
}

/// `add`: refuse first, so a refused check writes nothing; then create the file and heading
/// as needed and append the row.
fn add_in(
    log: &Logger,
    dir: &Path,
    project: &str,
    game: Option<&str>,
    pr: Option<u64>,
    text: &str,
) -> Result<i32> {
    let text = checked("check", text)?;
    let game = match game {
        Some(g) => checked("--game", g)?,
        None => DEFAULT_GAME,
    };
    let mut row = format!("- [ ] {text}");
    if let Some(n) = pr {
        row.push_str(&format!(" (pr:{n})"));
    }
    let file = path(dir);
    let content = if file.exists() {
        fs::read_to_string(&file)?
    } else {
        header(project)
    };
    md::write_atomic(&file, &insert_row(&content, game, &row))?;
    log.info(
        "ptask",
        &format!("playtest added to {} ({project})", file.display()),
    );
    println!("{row}");
    Ok(0)
}

/// `done`: the sheet's own evidence gate (`--proof` or `--unverified`), stamped on the row.
fn done_in(
    log: &Logger,
    dir: &Path,
    project: &str,
    query: &str,
    proof: Option<&str>,
    unverified: Option<&str>,
) -> Result<i32> {
    let stamp = project_tasks::proof_stamp(proof, unverified)?;
    edit_in(log, dir, project, query, "done", |l| {
        Some(md::add_marker(&md::set_checkbox(l, 'x'), &stamp))
    })
}

/// Shared body for `done`/`rm`: apply `f` to the first open row matching `query` (the sheet's
/// own `project_tasks::is_match`). Non-zero exit on no match, as the sheet verbs do.
fn edit_in<F>(log: &Logger, dir: &Path, project: &str, query: &str, verb: &str, f: F) -> Result<i32>
where
    F: FnOnce(&str) -> Option<String>,
{
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        bail!("which one? (provide a word from the check)");
    }
    let file = path(dir);
    if !file.exists() {
        bail!("'{project}' has no playtest.md yet - add a check with `notes ptask {project} --playtest add \"...\"`");
    }
    let content = fs::read_to_string(&file)?;
    let hit = open_rows(&content)
        .into_iter()
        .find(|(_, _, l)| project_tasks::is_match(l, &query))
        .and_then(|(_, g, _)| {
            md::edit_first_in_section(&content, &g, |l| project_tasks::is_match(l, &query), f)
        });
    match hit {
        Some((new, matched)) => {
            md::write_atomic(&file, &new)?;
            log.info(
                "ptask",
                &format!("playtest {verb} in {} ({project})", file.display()),
            );
            println!("{verb} {}", matched.trim());
            Ok(0)
        }
        None => {
            eprintln!("no open playtest check matches '{query}' in {project}");
            Ok(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch project dir, unique per test and per thread, plus a logger inside it.
    fn scratch(tag: &str) -> (PathBuf, Logger) {
        let dir = std::env::temp_dir().join(format!(
            "playtest-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let log = Logger::new(dir.join("log/journal.log"), false);
        (dir, log)
    }

    #[test]
    fn add_creates_the_file_the_heading_and_the_row() {
        let (dir, log) = scratch("create");
        assert_eq!(
            add_in(
                &log,
                &dir,
                "dodginballs",
                None,
                None,
                "arena: spawn 4 bots, none clip"
            )
            .unwrap(),
            0
        );
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert!(
            got.starts_with("# Playtest\n\nOne row is one thing to play"),
            "{got}"
        );
        assert!(
            got.contains("`notes ptask dodginballs --playtest add`"),
            "{got}"
        );
        assert!(
            got.ends_with("\n\n## General\n- [ ] arena: spawn 4 bots, none clip\n"),
            "{got}"
        );

        add_in(
            &log,
            &dir,
            "dodginballs",
            Some("Dodgeball"),
            Some(812),
            "menu: back exits",
        )
        .unwrap();
        add_in(
            &log,
            &dir,
            "dodginballs",
            Some("general"),
            None,
            "lobby: two pads join",
        )
        .unwrap();
        let got = fs::read_to_string(path(&dir)).unwrap();
        // a second row lands at the foot of its existing heading, not a second heading
        assert_eq!(got.matches("## General").count(), 1, "{got}");
        assert!(
            got.contains(
                "## General\n- [ ] arena: spawn 4 bots, none clip\n- [ ] lobby: two pads join\n"
            ),
            "{got}"
        );
        assert!(
            got.contains("## Dodgeball\n- [ ] menu: back exits (pr:812)\n"),
            "{got}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn add_refuses_what_is_not_one_short_ascii_line() {
        for (bad, why) in [
            ("", "empty"),
            ("   ", "empty"),
            ("play the arena\nthen the menu", "more than one line"),
            (&"x".repeat(201) as &str, "over 200"),
            ("arena: the ball \u{2014} clips", "ASCII"),
        ] {
            let e = checked("check", bad).unwrap_err().to_string();
            assert!(e.contains(why), "{bad:?}: {e}");
            assert!(e.contains("several rows"), "{e}");
        }
        assert_eq!(checked("check", &"x".repeat(200)).unwrap().len(), 200);
        assert!(checked("--game", "Dodge\nball").is_err());
    }

    // NEGATIVE CONTROL: a refusal must leave an existing file byte-identical.
    #[test]
    fn a_refused_add_writes_nothing() {
        let (dir, log) = scratch("refuse");
        add_in(&log, &dir, "demo", None, None, "arena: one round").unwrap();
        let before = fs::read(path(&dir)).unwrap();
        assert!(add_in(&log, &dir, "demo", None, None, "a\nb").is_err());
        assert!(add_in(&log, &dir, "demo", None, None, "caf\u{e9}").is_err());
        assert!(add_in(&log, &dir, "demo", Some(""), None, "fine text").is_err());
        assert_eq!(fs::read(path(&dir)).unwrap(), before);

        // and with no file yet, a refusal does not create one
        let (empty, log2) = scratch("refuse-none");
        assert!(add_in(&log2, &empty, "demo", None, None, "").is_err());
        assert!(!path(&empty).exists());
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }

    const FILE: &str = "\
# Playtest

One row is one thing to play and check off.

## General
- [ ] lobby: two pads join
- [x] title: logo fades <!-- pr:1 -->

## Dodgeball
- [ ] arena: ball never clips the wall
";

    #[test]
    fn list_is_tsv_of_open_rows_with_their_game() {
        let (dir, _) = scratch("list");
        fs::write(path(&dir), FILE).unwrap();
        let f = path(&dir).display().to_string();
        assert_eq!(
            list_rows(&path(&dir)),
            vec![
                format!("{f}\t6\tGeneral\tlobby: two pads join"),
                format!("{f}\t10\tDodgeball\tarena: ball never clips the wall"),
            ]
        );
        assert_eq!(open_count(&dir), 2);
        assert!(list_rows(&dir.join("nope.md")).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn done_needs_evidence_and_checks_the_row_off() {
        let (dir, log) = scratch("done");
        fs::write(path(&dir), FILE).unwrap();
        // the gate is the sheet's own: no evidence, no tick, and nothing written
        let e = done_in(&log, &dir, "demo", "arena", None, None)
            .unwrap_err()
            .to_string();
        assert!(e.contains("--proof") && e.contains("--unverified"), "{e}");
        assert_eq!(fs::read_to_string(path(&dir)).unwrap(), FILE);

        assert_eq!(
            done_in(&log, &dir, "demo", "ARENA", None, Some("played it")).unwrap(),
            0
        );
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert!(
            got.contains("- [x] arena: ball never clips the wall <!-- unverified: played it -->"),
            "{got}"
        );
        assert_eq!(open_count(&dir), 1);
        // a closed row is not matched again
        assert_eq!(
            done_in(&log, &dir, "demo", "arena", Some("pr:2"), None).unwrap(),
            1
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rm_deletes_the_first_open_match_only() {
        let (dir, log) = scratch("rm");
        fs::write(path(&dir), FILE).unwrap();
        assert_eq!(
            edit_in(&log, &dir, "demo", "lobby", "removed", |_| None).unwrap(),
            0
        );
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert!(!got.contains("lobby"), "{got}");
        assert!(got.contains("- [x] title: logo fades"), "{got}");
        assert!(got.contains("arena: ball never clips"), "{got}");
        // checked rows are not open, so `rm` cannot reach them
        assert_eq!(
            edit_in(&log, &dir, "demo", "logo", "removed", |_| None).unwrap(),
            1
        );
        // and with no file there is nothing to act on
        let (empty, _) = scratch("rm-none");
        assert!(edit_in(&log, &empty, "demo", "x", "removed", |_| None).is_err());
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }
}
