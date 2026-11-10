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
//!
//! Every write ends with the same kind of sweep a sheet gets ([`lay_out`]): within a game the
//! open checks are grouped by the PR they came from under `### PR <n>`, newest first, and the
//! ticked ones sit in `### Done` for the sheet's Done window, then roll into the version note.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use crate::project_tasks::{self, Pick};
use crate::projects;
use crate::sweep::Block;
use anyhow::{bail, Result};
use chrono::NaiveDate;
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
        pick: Pick,
    },
    /// Close a check undelivered; `stamp` is `project_tasks::drop_stamp`'s marker.
    Drop {
        stamp: String,
        pick: Pick,
    },
    /// File the one human sheet row a playtest pass of a cut build is: its open checks, counted.
    Pass {
        build: String,
        game: Option<String>,
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
            pick,
        } => done_in(
            log,
            &dir,
            &project,
            &pick,
            proof.as_deref(),
            unverified.as_deref(),
        ),
        Op::Drop { stamp, pick } => edit_in(log, &dir, &project, &pick, "dropped", |l| {
            Some(md::add_marker(&md::set_checkbox(l, 'x'), &stamp))
        }),
        Op::Pass { build, game } => pass_in(p, log, name, &dir, &build, game.as_deref()),
    }
}

/// `pass`: one `check(playtest): play [<game> ]build <build>, N checks in playtest.md #high` row
/// on the human sheet, N the open checks (of `game`, when given). The checks stay in
/// playtest.md; the row is the one thing on the human's list that says a build waits to be
/// played. The sheet's twin rule makes it idempotent: the same build again is exit 3.
fn pass_in(
    p: &Profile,
    log: &Logger,
    name: &str,
    dir: &Path,
    build: &str,
    game: Option<&str>,
) -> Result<i32> {
    let build = checked("--build", build)?;
    let game = game.map(|g| checked("--game", g)).transpose()?;
    let content = fs::read_to_string(path(dir)).unwrap_or_default();
    let n = open_rows(&content)
        .iter()
        .filter(|(_, g, _)| game.is_none_or(|w| g.eq_ignore_ascii_case(w)))
        .count();
    if n == 0 {
        println!(
            "no open playtest checks{} in {name}: nothing to play, no row filed",
            game.map_or(String::new(), |g| format!(" under ## {g}"))
        );
        return Ok(0);
    }
    let what = game.map_or(String::new(), |g| format!("{g} "));
    let s = if n == 1 { "" } else { "s" };
    let text =
        format!("check(playtest): play {what}build {build}, {n} check{s} in playtest.md #high");
    project_tasks::add_via(
        p,
        log,
        name,
        &text,
        &[],
        None,
        None,
        crate::agent_sheet::Lane::Human,
        None,
    )
}

/// The head a new playtest.md starts with: the title and the one rule every row follows.
pub(crate) fn header(project: &str) -> String {
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
pub(crate) fn open_rows(content: &str) -> Vec<(usize, String, &str)> {
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
    // The PR goes in the marker comment, where every sheet keeps its `pr:` and `done` adds
    // its proof, so one reader finds it on any row.
    let mut row = format!("- [ ] {text}");
    if let Some(n) = pr {
        row = md::add_marker(&row, &format!("pr:{n}"));
    }
    let file = path(dir);
    let content = if file.exists() {
        fs::read_to_string(&file)?
    } else {
        header(project)
    };
    write_swept(dir, project, &insert_row(&content, game, &row))?;
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
    pick: &Pick,
    proof: Option<&str>,
    unverified: Option<&str>,
) -> Result<i32> {
    let stamp = project_tasks::proof_stamp(proof, unverified)?;
    // `done:` first, as the sheet's `done` stamps it: the day the Done window counts from.
    let on = project_tasks::done_token(chrono::Local::now().date_naive());
    edit_in(log, dir, project, pick, "done", |l| {
        let ticked = md::add_marker(&md::set_checkbox(l, 'x'), &on);
        Some(md::add_marker(&ticked, &stamp))
    })
}

/// Shared body for `done`/`rm`: apply `f` to the first open row `pick` names (the sheet's
/// own matcher). Non-zero exit on no match, as the sheet verbs do.
fn edit_in<F>(log: &Logger, dir: &Path, project: &str, pick: &Pick, verb: &str, f: F) -> Result<i32>
where
    F: FnOnce(&str) -> Option<String>,
{
    let file = path(dir);
    if !file.exists() {
        bail!("'{project}' has no playtest.md yet - add a check with `notes ptask {project} --playtest add \"...\"`");
    }
    let content = fs::read_to_string(&file)?;
    // Words on two open checks act on neither (nc-47), as the sheet verbs do.
    let open = open_rows(&content);
    let hits: Vec<&str> = open.iter().map(|r| r.2).filter(|l| pick.hits(l)).collect();
    let pick = &pick.sole_among(&hits, &file)?;
    let hit = open
        .iter()
        .find(|(_, _, l)| pick.hits(l))
        .and_then(|(_, g, _)| md::edit_first_in_section(&content, g, |l| pick.hits(l), f));
    match hit {
        Some((new, matched)) => {
            write_swept(dir, project, &new)?;
            log.info(
                "ptask",
                &format!("playtest {verb} in {} ({project})", file.display()),
            );
            println!("{verb} {}", matched.trim());
            Ok(0)
        }
        None => {
            eprintln!("no open playtest check matches '{pick}' in {project}");
            Ok(1)
        }
    }
}

/// A heading or rule this sweep writes, so a re-sweep drops it and lays it out afresh, and an
/// authored line anywhere else stays as prose.
fn is_scaffold(line: &str) -> bool {
    let t = line.trim();
    t == "---"
        || t.eq_ignore_ascii_case("### Done")
        || t.eq_ignore_ascii_case(NO_PR)
        || t.strip_prefix("### PR ")
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// The group heading for checks that name no PR.
const NO_PR: &str = "### No PR";

/// The PR a check came from, its build: the `pr:` token of its marker.
fn build_of(row: &str) -> Option<u64> {
    md::marker_token(row, "pr:").and_then(|n| n.parse().ok())
}

/// One `## <game>` section taken apart: authored prose lines, then the open and the ticked
/// check blocks, each a row and the lines indented under it.
#[derive(Default)]
struct Game {
    name: String,
    prose: Vec<String>,
    open: Vec<Block>,
    done: Vec<Block>,
}

/// The file taken apart: the lines above the first `## `, and each game in file order. A game
/// heading that repeats folds into its first occurrence, the one every verb already acts in.
fn parse(content: &str) -> (Vec<String>, Vec<Game>) {
    let mut head: Vec<String> = Vec::new();
    let mut games: Vec<Game> = Vec::new();
    let mut cur: Option<usize> = None;
    // Where an indented line goes: the block the last top-level row opened.
    let mut last: Option<bool> = None;
    for l in content.lines() {
        if let Some(h) = l.strip_prefix("## ") {
            let h = h.trim();
            cur = Some(
                match games.iter().position(|g| g.name.eq_ignore_ascii_case(h)) {
                    Some(i) => i,
                    None => {
                        games.push(Game {
                            name: h.to_string(),
                            ..Game::default()
                        });
                        games.len() - 1
                    }
                },
            );
            last = None;
            continue;
        }
        let Some(gi) = cur else {
            head.push(l.to_string());
            continue;
        };
        let g = &mut games[gi];
        if l.trim().is_empty() || md::is_empty_unchecked(l) || is_scaffold(l) {
            if !l.trim().is_empty() {
                last = None;
            }
            continue;
        }
        if l.starts_with(char::is_whitespace) {
            let into = match last {
                Some(true) => g.done.last_mut(),
                Some(false) => g.open.last_mut(),
                None => None,
            };
            if let Some(b) = into {
                b.push(l.to_string());
                continue;
            }
        }
        if md::is_task(l) && !l.starts_with(char::is_whitespace) {
            let done = md::is_checked(l);
            if done { &mut g.done } else { &mut g.open }.push(vec![l.to_string()]);
            last = Some(done);
        } else {
            g.prose.push(l.to_string());
            last = None;
        }
    }
    while head.last().is_some_and(|l| l.trim().is_empty()) {
        head.pop();
    }
    (head, games)
}

/// What a sweep of playtest.md made: the file, and the ticked checks it rolled off, by game.
pub(crate) struct Laid {
    pub content: String,
    pub old: Vec<(String, Vec<Block>)>,
}

/// Pure core: lay `content` out. In each game, the open checks grouped under `### PR <n>`,
/// newest PR first and file order within one, the checks with no PR last under `### No PR`;
/// then `### Done`, the ticked checks the sheet's Done window keeps, newest first. A ticked check
/// that is undated, dropped, older than `done_days` or past the `done_max` newest leaves for
/// [`Laid::old`], the rule [`crate::project_sweep::old_done`] holds a sheet to. A file with no
/// `## ` heading comes back as it is.
pub(crate) fn lay_out(content: &str, today: NaiveDate, shape: &crate::config::SheetShape) -> Laid {
    let (head, games) = parse(content);
    if games.is_empty() {
        return Laid {
            content: content.to_string(),
            old: Vec::new(),
        };
    }
    let mut out: Vec<String> = head;
    let mut old: Vec<(String, Vec<Block>)> = Vec::new();
    for mut g in games {
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push(format!("## {}", g.name));
        out.append(&mut g.prose);
        g.open
            .sort_by_key(|b| build_of(&b[0]).map_or((1, 0), |n| (0, u64::MAX - n)));
        let mut at: Option<Option<u64>> = None;
        for b in g.open {
            let build = build_of(&b[0]);
            if at != Some(build) {
                if at.is_some() {
                    out.push(String::new());
                }
                out.push(build.map_or(NO_PR.to_string(), |n| format!("### PR {n}")));
                at = Some(build);
            }
            out.extend(b);
        }
        let day = |b: &Block| {
            project_tasks::done_on(&b[0])
                .filter(|_| !md::is_dropped(&b[0]))
                .filter(|d| (today - *d).num_days() < shape.done_days)
        };
        let (mut keep, mut gone): (Vec<(NaiveDate, Block)>, Vec<Block>) = (Vec::new(), Vec::new());
        for b in g.done {
            match day(&b) {
                Some(d) => keep.push((d, b)),
                None => gone.push(b),
            }
        }
        keep.sort_by_key(|(d, _)| std::cmp::Reverse(*d));
        gone.extend(
            keep.split_off(keep.len().min(shape.done_max))
                .into_iter()
                .map(|(_, b)| b),
        );
        if !keep.is_empty() {
            if at.is_some() {
                out.push(String::new());
            }
            out.push("### Done".to_string());
            out.extend(keep.into_iter().flat_map(|(_, b)| b));
        }
        if !gone.is_empty() {
            old.push((g.name, gone));
        }
    }
    Laid {
        content: format!("{}\n", out.join("\n")),
        old,
    }
}

/// The section of the version note a game's rolled-off checks go under.
fn archive_section(game: &str) -> String {
    format!("Playtest done: {game}")
}

/// Lay out `content`, a project's playtest.md under `dir`, rolling old ticked checks into the
/// version note of the human sheet's open version (unless `dry_run`). A profile with
/// `automation = false` is left as written. `None` when nothing would change.
pub(crate) fn tidy(
    dir: &Path,
    project: &str,
    content: &str,
    dry_run: bool,
) -> Result<Option<Laid>> {
    if !crate::config::managed_path(&path(dir)) {
        return Ok(None);
    }
    let laid = lay_out(
        content,
        chrono::Local::now().date_naive(),
        &crate::config::sheet_shape(),
    );
    if laid.content == content {
        return Ok(None);
    }
    if !dry_run {
        let cur = project_tasks::open_version_for(dir);
        for (game, rows) in &laid.old {
            project_tasks::archive_blocks(dir, project, cur, &archive_section(game), rows)?;
        }
    }
    Ok(Some(laid))
}

/// Write `content` as `dir`'s playtest.md, swept first: how every verb here writes, so no write
/// leaves the file out of shape.
fn write_swept(dir: &Path, project: &str, content: &str) -> Result<()> {
    let laid = tidy(dir, project, content, false)?;
    md::write_atomic(
        &path(dir),
        laid.as_ref().map_or(content, |l| l.content.as_str()),
    )
}

/// The report lines of one sweep: how many checks rolled off, and where to.
pub(crate) fn report(dir: &Path, laid: &Laid) -> Vec<String> {
    let ver = projects::version_or_default(project_tasks::open_version_for(dir));
    laid.old
        .iter()
        .map(|(game, rows)| {
            format!(
                "{} ticked check(s) -> {} ## {}",
                rows.len(),
                projects::agent_note_path(dir, &ver).display(),
                archive_section(game)
            )
        })
        .collect()
}

/// `notes sheet-sweep <dir>/playtest.md`: the save hook (`stdin`, which also dates a box
/// ticked by hand in this edit), the explicit sweep, or with `layout_only` the re-sort alone.
pub(crate) fn sheet_sweep(
    file: &Path,
    content: &str,
    stdin: bool,
    layout_only: bool,
    dry_run: bool,
) -> Result<i32> {
    let dir = file.parent().unwrap_or(Path::new("."));
    let project = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    if layout_only {
        let mut shape = crate::config::sheet_shape();
        // Nothing rolls off a re-sort: keep every ticked check where the window would.
        shape.done_days = i64::MAX / 2;
        shape.done_max = usize::MAX;
        let laid = lay_out(content, chrono::Local::now().date_naive(), &shape);
        print!("{}", laid.content);
        return Ok(0);
    }
    let content = if stdin {
        let saved = fs::read_to_string(file).unwrap_or_default();
        let n = content.lines().count();
        crate::project_sweep::stamp_undated_in(
            content,
            &saved,
            chrono::Local::now().date_naive(),
            0..n,
        )
    } else {
        content.to_string()
    };
    let laid = tidy(dir, &project, &content, dry_run)?;
    if stdin {
        print!(
            "{}",
            laid.as_ref()
                .map_or(content.as_str(), |l| l.content.as_str())
        );
        return Ok(0);
    }
    if let Some(l) = laid {
        for r in report(dir, &l) {
            println!("{r}");
        }
        if !dry_run {
            md::write_atomic(file, &l.content)?;
        }
    }
    Ok(0)
}

/// A row in the form `add --pr` wrote before the PR moved into the marker comment,
/// `<text> (pr:N)`, rewritten to `<text> <!-- pr:N -->`. `None` when the row carries no
/// trailing inline PR. A row whose marker already names that PR (a `done --proof pr:N`) only
/// loses the inline copy.
fn marker_form(line: &str) -> Option<String> {
    let (head, tail) = match line.find("<!--") {
        Some(i) => (line[..i].trim_end(), line[i..].trim_end()),
        None => (line.trim_end(), ""),
    };
    let at = head.rfind(" (pr:")?;
    let n = head[at + 5..].strip_suffix(')')?;
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let token = format!("pr:{n}");
    let mut out = head[..at].to_string();
    if !tail.is_empty() {
        out = format!("{out} {tail}");
    }
    let has = tail.split_whitespace().any(|w| w == token);
    Some(if has {
        out
    } else {
        md::add_marker(&out, &token)
    })
}

/// Rewrite every inline `(pr:N)` row of `dir`'s playtest.md to the marker form, for
/// `projects --migrate`. Returns how many rows changed; 0 and no write when there is none.
pub(crate) fn fold_inline_prs(dir: &Path) -> Result<usize> {
    let file = path(dir);
    let Ok(content) = fs::read_to_string(&file) else {
        return Ok(0);
    };
    let mut n = 0;
    let lines: Vec<String> = content
        .lines()
        .map(|l| match md::is_task(l).then(|| marker_form(l)).flatten() {
            Some(new) => {
                n += 1;
                new
            }
            None => l.to_string(),
        })
        .collect();
    if n > 0 {
        md::write_atomic(&file, &format!("{}\n", lines.join("\n")))?;
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(q: &str) -> Pick {
        Pick::new(q, false).unwrap()
    }

    // nc-47: words on two open checks write nothing; the whole check, or --exact, picks one.
    #[test]
    fn done_and_rm_refuse_words_on_two_checks() {
        let (dir, log) = scratch("ambig");
        let before = "# Playtest\n\n## G\n- [ ] menu: back exits\n- [ ] menu: back exits twice\n- [ ] lobby: join\n";
        fs::write(path(&dir), before).unwrap();
        let err = edit_in(&log, &dir, "p", &w("menu"), "done", |l| Some(l.into()))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("2 open rows") && err.contains("--exact"),
            "{err}"
        );
        let stamp = "<!-- dropped: x -->";
        let err = edit_in(&log, &dir, "p", &w("back"), "dropped", |l| {
            Some(format!("{l}{stamp}"))
        })
        .unwrap_err()
        .to_string();
        assert!(err.contains("2 open rows"), "{err}");
        assert_eq!(
            fs::read_to_string(path(&dir)).unwrap(),
            before,
            "nothing written"
        );
        // One hit, and the whole-words row over the longer one, still close.
        assert_eq!(
            edit_in(&log, &dir, "p", &w("lobby"), "done", |l| Some(
                md::set_checkbox(l, 'x')
            ))
            .unwrap(),
            0
        );
        assert_eq!(
            edit_in(&log, &dir, "p", &w("menu: back exits"), "done", |l| Some(
                md::set_checkbox(l, 'x')
            ))
            .unwrap(),
            0
        );
        // Only the twice row is still open; the two ticks, undated by a bare edit, rolled off.
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert!(
            got.ends_with("## G\n### No PR\n- [ ] menu: back exits twice\n"),
            "{got}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    fn shape(done_days: i64, done_max: usize) -> crate::config::SheetShape {
        crate::config::SheetShape {
            done_days,
            done_max,
        }
    }

    fn day(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn lay_out_groups_open_checks_by_pr_newest_first_and_keeps_the_head() {
        let before = "# Playtest\n\nThe rule.\n\n## G\nplay these first\n- [ ] a <!-- pr:3 -->\n\
                      - [ ] b\n- [ ] c <!-- pr:30 -->\n  a detail under c\n- [ ] d <!-- pr:3 -->\n\n\
                      ## H\n- [ ] e <!-- pr:1 -->\n\n## g\n- [ ] f <!-- pr:30 -->\n";
        let laid = lay_out(before, day("2026-11-09"), &shape(7, 30));
        assert_eq!(
            laid.content,
            "# Playtest\n\nThe rule.\n\n## G\nplay these first\n### PR 30\n- [ ] c <!-- pr:30 -->\n\
             \x20 a detail under c\n- [ ] f <!-- pr:30 -->\n\n### PR 3\n- [ ] a <!-- pr:3 -->\n\
             - [ ] d <!-- pr:3 -->\n\n### No PR\n- [ ] b\n\n## H\n### PR 1\n- [ ] e <!-- pr:1 -->\n"
        );
        assert!(laid.old.is_empty());
        let again = lay_out(&laid.content, day("2026-11-09"), &shape(7, 30));
        assert_eq!(
            again.content, laid.content,
            "a second sweep changes nothing"
        );
        // A file with no game heading is left as it is.
        let bare = "# Playtest\n\nnothing yet\n";
        assert_eq!(
            lay_out(bare, day("2026-11-09"), &shape(7, 30)).content,
            bare
        );
    }

    #[test]
    fn ticked_checks_keep_the_window_and_the_rest_roll_off() {
        let before = "# Playtest\n\n## G\n- [ ] open <!-- pr:2 -->\n\
                      - [x] old <!-- done:2026-10-01 pr:1 -->\n\
                      - [x] fresh <!-- done:2026-11-08 x -->\n\
                      - [x] newest <!-- done:2026-11-09 x -->\n\
                      - [x] undated <!-- x -->\n\
                      - [x] dropped <!-- done:2026-11-09 dropped: stale -->\n";
        let laid = lay_out(before, day("2026-11-09"), &shape(7, 30));
        assert_eq!(
            laid.content,
            "# Playtest\n\n## G\n### PR 2\n- [ ] open <!-- pr:2 -->\n\n### Done\n\
             - [x] newest <!-- done:2026-11-09 x -->\n- [x] fresh <!-- done:2026-11-08 x -->\n"
        );
        let gone: Vec<&str> = laid.old[0].1.iter().map(|b| b[0].as_str()).collect();
        assert_eq!(laid.old[0].0, "G");
        assert_eq!(gone.len(), 3, "{gone:?}");
        assert!(gone
            .iter()
            .all(|l| !l.contains("fresh") && !l.contains("newest")));
        // done_max keeps only the newest.
        let laid = lay_out(before, day("2026-11-09"), &shape(7, 1));
        assert!(laid.content.contains("newest") && !laid.content.contains("fresh"));
        assert_eq!(laid.old[0].1.len(), 4);
    }

    #[test]
    fn a_tick_made_by_hand_is_dated_by_the_save_and_kept() {
        let saved = "# Playtest\n\n## G\n- [ ] a <!-- pr:2 -->\n";
        let edited = "# Playtest\n\n## G\n- [x] a <!-- pr:2 -->\n";
        let n = edited.lines().count();
        let stamped =
            crate::project_sweep::stamp_undated_in(edited, saved, day("2026-11-09"), 0..n);
        assert!(
            stamped.contains("- [x] a <!-- pr:2 done:2026-11-09 -->"),
            "{stamped}"
        );
        let laid = lay_out(&stamped, day("2026-11-09"), &shape(7, 30));
        assert!(
            laid.content.contains("### Done\n- [x] a"),
            "{}",
            laid.content
        );
        assert!(laid.old.is_empty());
    }

    #[test]
    fn an_inline_pr_moves_into_the_marker_comment() {
        assert_eq!(
            marker_form("- [ ] Street: strafe: legs blend (pr:1280)").as_deref(),
            Some("- [ ] Street: strafe: legs blend <!-- pr:1280 -->")
        );
        // Done with that PR as proof: the inline copy goes, the marker stays as it was.
        assert_eq!(
            marker_form("- [x] logo fades (pr:1) <!-- pr:1 -->").as_deref(),
            Some("- [x] logo fades <!-- pr:1 -->")
        );
        // Done with other proof: both survive, in one comment.
        assert_eq!(
            marker_form("- [x] logo fades (pr:1) <!-- unverified: played -->").as_deref(),
            Some("- [x] logo fades <!-- unverified: played pr:1 -->")
        );
        assert_eq!(marker_form("- [ ] no pr here"), None);
        assert_eq!(marker_form("- [ ] prose (pr:abc)"), None);
        assert_eq!(
            marker_form("- [ ] mid (pr:4) text"),
            None,
            "only a trailing one"
        );
    }

    #[test]
    fn folding_rewrites_only_rows_and_is_idempotent() {
        let (dir, _log) = scratch("fold");
        let before = "# Playtest\n\nA prose line (pr:9)\n\n## G\n- [ ] a (pr:3)\n- [ ] b\n";
        fs::write(path(&dir), before).unwrap();
        assert_eq!(fold_inline_prs(&dir).unwrap(), 1);
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert_eq!(
            got,
            "# Playtest\n\nA prose line (pr:9)\n\n## G\n- [ ] a <!-- pr:3 -->\n- [ ] b\n"
        );
        assert_eq!(fold_inline_prs(&dir).unwrap(), 0);
        assert_eq!(fs::read_to_string(path(&dir)).unwrap(), got);
        let _ = fs::remove_dir_all(&dir);
    }

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
            got.ends_with("\n\n## General\n### No PR\n- [ ] arena: spawn 4 bots, none clip\n"),
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
                "## General\n### No PR\n- [ ] arena: spawn 4 bots, none clip\n- [ ] lobby: two pads join\n"
            ),
            "{got}"
        );
        assert!(
            got.contains("## Dodgeball\n### PR 812\n- [ ] menu: back exits <!-- pr:812 -->\n"),
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
        let e = done_in(&log, &dir, "demo", &w("arena"), None, None)
            .unwrap_err()
            .to_string();
        assert!(e.contains("--proof") && e.contains("--unverified"), "{e}");
        assert_eq!(fs::read_to_string(path(&dir)).unwrap(), FILE);

        assert_eq!(
            done_in(&log, &dir, "demo", &w("ARENA"), None, Some("played it")).unwrap(),
            0
        );
        let got = fs::read_to_string(path(&dir)).unwrap();
        let today = chrono::Local::now().date_naive();
        assert!(
            got.contains(&format!(
                "### Done\n- [x] arena: ball never clips the wall <!-- done:{today} unverified: played it -->"
            )),
            "{got}"
        );
        assert_eq!(open_count(&dir), 1);
        // a closed row is not matched again
        assert_eq!(
            done_in(&log, &dir, "demo", &w("arena"), Some("pr:2"), None).unwrap(),
            1
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rm_deletes_the_first_open_match_only() {
        let (dir, log) = scratch("rm");
        fs::write(path(&dir), FILE).unwrap();
        assert_eq!(
            edit_in(&log, &dir, "demo", &w("lobby"), "removed", |_| None).unwrap(),
            0
        );
        let got = fs::read_to_string(path(&dir)).unwrap();
        assert!(!got.contains("lobby"), "{got}");
        // The write sweeps: the undated tick rolls into the version note.
        assert!(!got.contains("title: logo fades"), "{got}");
        let note = fs::read_to_string(dir.join("agent/versions/v0.0.1.md")).unwrap();
        assert!(
            note.contains("## Playtest done: General\n- [x] title: logo fades"),
            "{note}"
        );
        assert!(got.contains("arena: ball never clips"), "{got}");
        // checked rows are not open, so `rm` cannot reach them
        assert_eq!(
            edit_in(&log, &dir, "demo", &w("logo"), "removed", |_| None).unwrap(),
            1
        );
        // and with no file there is nothing to act on
        let (empty, _) = scratch("rm-none");
        assert!(edit_in(&log, &empty, "demo", &w("x"), "removed", |_| None).is_err());
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }
}
