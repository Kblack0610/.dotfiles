//! `notes ptask <name> ...` - a project's task list, living in the project SHEET's `## Tasks`
//! section. The project analog of `notes focus` (which is the daily note's `## Focus`):
//! project tasks belong in the project `.md` - the template-driven, version-scoped source of
//! truth - so `notes projects --release` freezes a REAL task list into `versions/`, and the
//! daily note keeps only the untagged main tasks.
//!
//! Mirrors `focus.rs` verb-for-verb but points the SAME generic `md` helpers at `## Tasks`
//! instead of the hard-coded `## Focus`. The task SHEET is the README.md/tasks.md that carries
//! a `## Tasks` - decoupled from the `Version:` line, so a release-managed project (version in
//! `changelog/`) can hold a task sheet without owning its version there.

use crate::agent_sheet::Lane;
use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use crate::project_sweep;
use crate::projects;
use crate::sheet::{self, V};
use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

/// The version a directory's rows are read against: its own sheet's `Version:` line, else,
/// for an agent board (which carries none), the human sheet's one level up, else, for a game
/// the playground versions, the playground's ([`projects::version_parent_dir`]).
pub(crate) fn open_version_for(dir: &Path) -> Option<V> {
    let content = task_sheet(dir)
        .and_then(|s| fs::read_to_string(s).ok())
        .unwrap_or_default();
    version_in(dir, &content)
}

/// [`open_version_for`] for a caller already holding the sheet's text.
fn version_in(dir: &Path, content: &str) -> Option<V> {
    projects::sheet_version(content).or_else(|| match dir.parent() {
        Some(human) if dir.ends_with("agent") => open_version_for(human),
        _ => open_version_for(&projects::version_parent_dir(dir)?),
    })
}

/// A `--to`/`--version` argument as a version.
fn parse_to(to: &str) -> Result<V> {
    projects::parse_version(to.trim())
        .ok_or_else(|| anyhow::anyhow!("not a version: '{to}' (want vX.Y.Z)"))
}

/// Refuse a target behind the open version: a tag there is stale the moment it is written.
fn refuse_behind(to: V, cur: Option<V>) -> Result<()> {
    match cur.filter(|c| to < *c) {
        Some(c) => bail!(
            "{} is behind the open version {}",
            projects::fmt_version(to),
            projects::fmt_version(c)
        ),
        None => Ok(()),
    }
}

/// The project's TASK sheet: `README.md` then `tasks.md`, whichever carries a `## Tasks`.
///
/// `pub(crate)` because carrying a live sheet is also how cross-org name resolution picks
/// between two orgs holding the same slug (`projects::project_dir`) — the same rule
/// `lab_project_root` applies on the shell side, kept identical so both agree on which copy
/// is the real one.
pub(crate) fn task_sheet(dir: &Path) -> Option<PathBuf> {
    ["README.md", "tasks.md"].iter().find_map(|n| {
        let p = dir.join(n);
        fs::read_to_string(&p)
            .ok()
            .filter(|c| sheet::has_tasks(c))
            .map(|_| p)
    })
}

/// [`ensure_task_sheet`] for either lane: the project's own sheet, or its agent board.
fn ensure_lane_sheet(p: &Profile, proj_dir: &Path, name: &str, lane: Lane) -> Result<PathBuf> {
    match lane {
        Lane::Human => ensure_task_sheet(proj_dir, name),
        Lane::Agent => crate::agent_sheet::ensure_for(p, proj_dir, name),
    }
}

/// True when two paths are one sheet, through links; by name when either is missing.
fn same_sheet(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

/// Resolve (or create) a project's task sheet. Prefers an existing `## Tasks` sheet; else
/// appends the sections to an existing `README.md`; else scaffolds a fresh `README.md` task
/// sheet. `name` seeds the title of a fresh sheet.
fn ensure_task_sheet(dir: &Path, name: &str) -> Result<PathBuf> {
    if let Some(s) = task_sheet(dir) {
        return Ok(s);
    }
    let readme = dir.join("README.md");
    if let Ok(mut c) = fs::read_to_string(&readme) {
        if !c.ends_with('\n') {
            c.push('\n');
        }
        c.push('\n');
        c.push_str(&sheet::skeleton());
        md::write_atomic(&readme, &c)?;
    } else {
        fs::write(&readme, format!("# {name}\n\n{}", sheet::skeleton()))?;
    }
    Ok(readme)
}

/// A sheet's open version as `notes board --json` reads it: where the sheet is, its version,
/// and each open row of that version with its 1-based line number. Rows aimed at a later
/// release are left out.
pub(crate) struct OpenRows {
    pub sheet: PathBuf,
    pub version: String,
    pub rows: Vec<OpenRow>,
    /// Lines waiting in the sheet's `## Inbox`.
    pub inbox: usize,
    /// Closed rows past the Done window: the ones the next sweep rolls into `versions/`
    /// ([`project_sweep::old_done`]).
    pub done_old: usize,
}

/// One open row: its 1-based line, the line itself, and the lines indented under it.
pub(crate) struct OpenRow {
    pub line: usize,
    pub text: String,
    pub details: Vec<String>,
}

/// A directory's open version, `None` when it has no task sheet at all. The one reader the
/// JSON feed and the rendered board use, so they cannot list different rows.
///
/// Keyed by DIRECTORY rather than profile+name, because the board walks
/// `daily::discover_project_dirs` across every configured profile: it already holds the path
/// and has no name to re-resolve. Same sheet, same section, same open-task predicate the
/// cockpit and `ptask list` use, so the three cannot disagree about what is on a board.
pub(crate) fn current_rows_for_dir(dir: &Path) -> Option<OpenRows> {
    let path = task_sheet(dir)?;
    let content = fs::read_to_string(&path).ok()?;
    let cur = version_in(dir, &content);
    let ctx = project_sweep::Ctx {
        today: chrono::Local::now().date_naive(),
        shape: crate::config::sheet_shape(),
        open: cur,
        rewrite: false,
        systems: Vec::new(),
        tiered: false,
        aim: None,
    };
    let lines: Vec<&str> = content.lines().collect();
    let rows = sheet::current_rows(&content, cur)
        .into_iter()
        .map(|(n, l)| OpenRow {
            line: n,
            text: l.trim_end().to_string(),
            details: md::brief_details(&lines, n - 1),
        })
        .collect();
    Some(OpenRows {
        version: projects::version_or_default(cur),
        sheet: path,
        rows,
        inbox: sheet::inbox_lines(&content).len(),
        done_old: project_sweep::old_done(&content, &ctx).len(),
    })
}

/// The directory a verb acts in: the project's own, or its agent board's.
///
/// Every verb resolves through here so `--agent` is one decision made once, rather than a
/// path choice repeated at eight call sites that can each get it wrong.
fn lane_dir(p: &Profile, name: &str, lane: Lane) -> Result<PathBuf> {
    Ok(lane.dir(&projects::project_dir(p, name)?))
}

/// The sheet and its text, for a named project. `None` when the project has no task sheet yet
/// (a read verb then lists nothing).
fn sheet_and_content(p: &Profile, name: &str, lane: Lane) -> Result<Option<(PathBuf, String)>> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        return Ok(None);
    };
    let content = fs::read_to_string(&sheet)?;
    Ok(Some((sheet, content)))
}

/// An open task matching `query` (already lower-cased) - the shared predicate for
/// `done`/`start`/`rm`, matching `focus.rs::is_match`.
pub(crate) fn is_match(line: &str, query: &str) -> bool {
    md::is_open_task(line) && md::task_key(line).contains(query)
}

/// Which row a verb acts on: the first open task whose text contains some words, the open
/// task carrying an id (a query shaped like one, `ar-142`), or the one open task whose line
/// is exactly `raw`.
///
/// `Exact` is for a UI. It shows a row from `notes board --json` and acts on that row's `raw`
/// field, so the write is optimistic concurrency without id stamps in the sheets: when the
/// line was edited, ticked or removed since the UI read it, nothing matches, nothing is
/// written, and the verb exits 1 so the UI refreshes. Words could hit a different row.
/// The Backlog tier token is not an edit: the sweep after any write moves it on and off rows
/// the UI never touched, so the line is compared without it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Pick {
    Words(String),
    Id(String),
    Exact(String),
}

impl Pick {
    /// The pick for `query`, refusing an empty one: an empty query matches every row.
    pub(crate) fn new(query: &str, exact: bool) -> Result<Pick> {
        if exact {
            let raw = query.trim_end();
            if !md::is_open_task(raw) {
                bail!("--exact takes a whole open task line, as `notes board --json` prints it in `raw`");
            }
            return Ok(Pick::Exact(raw.to_string()));
        }
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            bail!("which one? (provide a word from the task)");
        }
        if md::is_row_id(&q) {
            return Ok(Pick::Id(q));
        }
        Ok(Pick::Words(q))
    }

    /// Whether `line` is the row this pick names.
    pub(crate) fn hits(&self, line: &str) -> bool {
        match self {
            Pick::Words(q) => is_match(line, q),
            Pick::Id(id) => md::is_open_task(line) && md::row_id(line).as_deref() == Some(id),
            Pick::Exact(raw) => {
                md::is_open_task(line)
                    && project_sweep::with_backlog(line.trim_end(), false)
                        == project_sweep::with_backlog(raw, false)
            }
        }
    }

    /// Refuse an exact pick whose line is on `sheet` more than once. Twin rows cannot be
    /// told apart by their text, and the verb would act on whichever comes first, which may
    /// be aimed at another release than the one the UI showed. A missing sheet passes: the
    /// verb itself reports that.
    pub(crate) fn sole_in(&self, sheet: &Path) -> Result<()> {
        if let Pick::Exact(raw) = self {
            let n = fs::read_to_string(sheet)
                .map(|c| c.lines().filter(|l| self.hits(l)).count())
                .unwrap_or(0);
            if n > 1 {
                bail!(
                    "'{raw}' is on {} {n} times; --exact cannot tell twins apart, so nothing was written (edit one by hand)",
                    sheet.display()
                );
            }
        }
        Ok(())
    }

    /// The pick a verb on `sheet` acts on, refused when it could act on the wrong row (nc-47).
    /// [`Pick::sole_in`] refuses twin exact lines. Words that hit more than one open row of
    /// `## Tasks` are refused with each row's id, unless exactly one of them is those words
    /// whole (its [`md::task_key`]), which is picked by its line. An id on two open rows is
    /// refused. A missing sheet passes: the verb itself reports that.
    pub(crate) fn resolve_in(self, sheet: &Path) -> Result<Pick> {
        if let Pick::Exact(_) = self {
            self.sole_in(sheet)?;
            return Ok(self);
        }
        let Ok(content) = fs::read_to_string(sheet) else {
            return Ok(self);
        };
        let lines: Vec<&str> = content.lines().collect();
        let Some(span) = md::section_span(&lines, sheet::TASKS) else {
            return Ok(self);
        };
        let rows: Vec<&str> = lines[span]
            .iter()
            .copied()
            .filter(|l| self.hits(l))
            .collect();
        self.sole_among(&rows, sheet)
    }

    /// The pick for the open rows `hits` it hits, all on `sheet`: unchanged for one or none,
    /// the whole-words row when exactly one is those words whole, else refused naming each
    /// row's id. The one rule behind [`Pick::resolve_in`] and the playtest verbs.
    pub(crate) fn sole_among(&self, hits: &[&str], sheet: &Path) -> Result<Pick> {
        if hits.len() < 2 {
            return Ok(self.clone());
        }
        if let Pick::Words(q) = self {
            let whole: Vec<&&str> = hits.iter().filter(|l| md::task_key(l) == *q).collect();
            if let [one] = whole[..] {
                return Ok(Pick::Exact(one.trim_end().to_string()));
            }
        }
        let named: Vec<String> = hits
            .iter()
            .map(|l| {
                let text: String = md::task_text(l).chars().take(70).collect();
                format!(
                    "  {}  {text}",
                    md::row_id(l).unwrap_or_else(|| "(no id)".into())
                )
            })
            .collect();
        bail!(
            "'{self}' matches {} open rows in {}, so nothing was written; name one by its id or pass --exact with its whole line (twin lines: edit one by hand):\n{}",
            hits.len(),
            sheet.display(),
            named.join("\n")
        )
    }
}

/// The task sheet a ptask verb on `name` and `lane` reads, if the project has one.
pub(crate) fn sheet_of(p: &Profile, name: &str, lane: Lane) -> Result<Option<PathBuf>> {
    Ok(task_sheet(&lane_dir(p, name, lane)?))
}

impl std::fmt::Display for Pick {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Pick::Words(q) | Pick::Id(q) | Pick::Exact(q) => f.write_str(q),
        }
    }
}

/// `notes ptask <name> list [--version vX.Y.Z | --all]` - TSV of OPEN tasks.
///
/// Bare `list` is the open version and emits exactly the four columns it always has -
/// `path<TAB>line<TAB>key<TAB>text` - because the cockpit parses it. A version SELECTOR adds a
/// fifth column (the row's version, `-` when the sheet has none) rather than changing the
/// first four, so a reader that only wants `$1..$4` is unaffected either way.
pub fn list(p: &Profile, name: &str, version: Option<&str>, all: bool, lane: Lane) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(path) = task_sheet(&dir) else {
        return Ok(0);
    };
    let content = fs::read_to_string(&path)?;
    let file = path.display();
    let cur = version_in(&dir, &content);

    if !all && version.is_none() {
        for (n, l) in sheet::current_rows(&content, cur) {
            println!("{file}\t{n}\t{}\t{}", md::task_key(l), l.trim_end());
        }
        return Ok(0);
    }

    let want = version.map(parse_to).transpose()?;
    for (n, l) in sheet::open_rows(&content) {
        let v = sheet::version_of(l, cur);
        if want.is_some() && v != want {
            continue;
        }
        println!(
            "{file}\t{n}\t{}\t{}\t{}",
            md::task_key(l),
            l.trim_end(),
            v.map_or_else(|| "-".to_string(), projects::fmt_version)
        );
    }
    Ok(0)
}

/// `notes ptask <name> add <text> [--to vX.Y.Z]` - add `- [ ] <text>` to `## Tasks`, creating
/// the task sheet if the project has none. `--to` tags it for that release, which is the whole
/// roadmap-forward loop: plan into `v1.14.0` while `v1.13.0` is still running.
///
/// `want` is the channel a human's want came in by ([`projects::WANT_CHANNELS`]): an agent-lane
/// row then gets `#requested` from this writer, so no caller composes the tag, and the ingest
/// event names the channel. A human-lane row is the human's by its sheet, so it takes no tag.
///
/// The row is stamped as README "The task row" says: its created tag (`#cMMDD`), the default
/// priority when it has none, and its id (`<!-- id:<code>-<n> -->`, [`next_id`]) when the
/// registry gives the project a `code`. Each of `details` becomes an indented line under it,
/// after any later lines of a multi-line `text`, whose first line alone is the row.
///
/// On the human sheet, text with no `type(area): ` prefix is the human's own words, so it goes
/// to `## Inbox` as typed (plus the `--to` tag), unstamped, for the triager to file
/// ([`file`]). Nothing raw lands on the board. Agent-lane adds are typed by their writers.
///
/// A typed leaf with no `#of/` whose area is one of the project's systems goes under that
/// system's standing epic ([`link_standing`]), filed after every refusal and before the row.
///
/// A typed add by a queue item or a runner is no row, on either lane and an epic too: it goes to
/// the outbox as `[#agent] #p:<name> #from/<writer> [#want/<channel>] <text>` and the command
/// exits [`EXIT_INBOXED`], unless `writer` ([`Writer`]) is a plan's phases or on
/// `agent_direct_filers`, both vouched for by the process, not the flags. A hand session files only
/// after [`self_check`], exiting [`EXIT_SHORTLIST`] until it names every similar row it is shown.
/// Twin refusals (exit 3) come first; a hand session's or triage's epic names a system.
#[allow(clippy::too_many_arguments)]
pub fn add(
    p: &Profile,
    log: &Logger,
    name: &str,
    text: &str,
    details: &[String],
    to: Option<&str>,
    want: Option<&str>,
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    add_via(
        p,
        log,
        name,
        text,
        details,
        to,
        want,
        lane,
        writer,
        Some(crate::standing::SYSTEMS_BIN),
    )
}

/// [`add`] with the systems command named (a test points it at a stub), or None once the row
/// has its link, so the second pass never looks it up again.
#[allow(clippy::too_many_arguments)]
pub(crate) fn add_via(
    p: &Profile,
    log: &Logger,
    name: &str,
    text: &str,
    details: &[String],
    to_arg: Option<&str>,
    want_arg: Option<&str>,
    lane: Lane,
    writer: &Writer,
    systems: Option<&str>,
) -> Result<i32> {
    let typed = text.trim();
    // A stamped row's text is its first line and any later lines go before its details, so
    // the tags and id marker land on the row line, the only line a pick or the board reads.
    let (text, more) = typed.split_once('\n').unwrap_or((typed, ""));
    let text = text.trim_end();
    if text.is_empty() {
        bail!("nothing to add (provide task text)");
    }
    let mut row_details = details.to_vec();
    if !more.trim().is_empty() {
        row_details.insert(0, md::dedent(more));
    }
    let want = want_arg.map(projects::want_channel).transpose()?;
    let proj_dir = projects::project_dir(p, name)?;
    let to = to_arg.map(parse_to).transpose()?;
    let cur = open_version_for(&lane.dir(&proj_dir));
    if let Some(v) = to {
        refuse_behind(v, cur)?;
    }
    // Who writes decides first: a row from an inboxing writer, on either lane and an epic too,
    // is a proposal for inbox-triage, and only a direct agent-lane write is refused an epic.
    let inbox = writer.inboxes();
    if !inbox {
        refuse_epic_on_board(lane, &[text])?;
    }
    if lane == Lane::Agent && !projects::is_typed(text) {
        bail!("'{text}' is not `type(area): title` (README \"The task row\"); the agent board takes typed rows only, so nothing was added");
    }
    let path = ensure_lane_sheet(p, &proj_dir, name, lane)?;
    let content = fs::read_to_string(&path)?;
    if lane == Lane::Human && !projects::is_typed(text) {
        let mut line = format!("- [ ] {typed}");
        if let Some(v) = to {
            line = md::add_tag(&line, &projects::fmt_version(v));
        }
        let mut block = vec![line];
        block.extend(md::detail_lines("", details));
        let path = inbox_put(p, &proj_dir, name, &block)?;
        log.info("ptask", &format!("inboxed in {} ({name})", path.display()));
        let mut ev = crate::ingest::Event::row("added", name, "", lane.name(), &block[0]);
        ev.want = want.map(str::to_string);
        crate::ingest::record(p, &ev);
        println!("inbox: {}", block.join("\n"));
        return Ok(0);
    }
    if refuse_twin(&path, &content, text) {
        return Ok(3);
    }
    let mut block = new_rows(
        name,
        &proj_dir,
        &[text.to_string()],
        to,
        cur,
        &[],
        &row_details,
    )?;
    if want.is_some() && lane == Lane::Agent {
        block[0] = md::add_tag(&block[0], WANT_TAG);
    }
    // A hand session's row is held to the board's grammar (type, title length, id), as triage's is.
    let grammar = writer.self_checks() && lane == Lane::Agent;
    if let Some(why) = projects::row_findings(&block.join("\n"), grammar).first() {
        bail!("{why}, so nothing was added");
    }
    note_refused(writer, inbox);
    // A session's row is no row yet: the outbox holds it for inbox-triage, which checks it
    // against the board. Only the writers `Writer` lets through file now; a `--want` rides on
    // the outbox line and lets no automated writer past.
    if inbox {
        if to.is_some() {
            bail!("--to is not kept on a follow-up that goes to the outbox, so nothing was added");
        }
        return inbox_followup(p, log, name, lane, text, want, &row_details);
    }
    let canon = proj_dir
        .file_name()
        .map_or(name.into(), |n| n.to_string_lossy());
    if writer.checks_epic_system() {
        refuse_unknown_system(text, &canon, systems)?;
    }
    let mut checked = Vec::new();
    if writer.self_checks() {
        match self_check(p, name, text, &block[0], &writer.checked)? {
            Ok(shown) => checked = shown,
            Err(rc) => return Ok(rc),
        }
    }
    if let Some(bin) = systems {
        if let Some(linked) = link_standing(p, log, name, &proj_dir, &[text.to_string()], bin)? {
            return add_via(
                p,
                log,
                name,
                &linked[0],
                &row_details,
                to_arg,
                want_arg,
                lane,
                writer,
                None,
            );
        }
    }
    // A frozen release window takes a new row only through its interrupt lane.
    // A person at a terminal is the human's own new ask.
    let interrupt = writer.person || want.is_some_and(crate::window::human_channel);
    let block = crate::window::admit(&proj_dir, cur, block, interrupt);
    let new = md::insert_under_heading(&content, sheet::TASKS, &block);
    write_sheet(&path, &new)?;
    note_ids(&proj_dir, &block)?;
    log.info("ptask", &format!("added to {} ({name})", path.display()));
    let mut ev = crate::ingest::Event::row("added", name, "", lane.name(), &block[0]);
    ev.want = want.map(str::to_string);
    ev.origin = writer.name.clone().filter(|_| lane == Lane::Agent);
    if writer.self_checks() {
        ev.why = Some(SELF_CHECK.into());
        ev.checked = checked;
    }
    crate::ingest::record(p, &ev);
    for l in &block {
        println!("{l}");
    }
    Ok(0)
}

/// Does `text` twin an open row of `content` (the sheet at `path`): the same words, a near twin, or a
/// row that already lands the PR it names. Each says which row on stderr; the add exits 3.
fn refuse_twin(path: &Path, content: &str, text: &str) -> bool {
    if let Some(open) = open_twin(content, text) {
        eprintln!("already open on {}: {}", path.display(), open.trim());
    } else if let Some(near) = near_twin(content, text) {
        eprintln!(
            "near-duplicate of an open row on {}: {}",
            path.display(),
            near.trim()
        );
    } else if let Some((open, pr)) = pr_twin(content, text) {
        eprintln!(
            "already open on {}: {} already lands PR #{pr}: {}",
            path.display(),
            md::row_id(open).unwrap_or_else(|| "a row".into()),
            open.trim()
        );
    } else {
        return false;
    }
    true
}

/// An `--origin` the process did not vouch for, said on stderr with where the row goes instead.
fn note_refused(writer: &Writer, inbox: bool) {
    if let Some(o) = &writer.refused {
        let then = if inbox {
            "the row goes to the outbox"
        } else {
            "the session checks the row itself"
        };
        eprintln!("--origin {o} is neither this runner's AGENTCTL_NAME nor the script that ran notes, so {then}");
    }
}

/// What `ptask add` exits with when a hand session's add has a shortlist entry it has not named
/// in `--checked`: no row was written, and the shortlist is on stdout.
pub const EXIT_SHORTLIST: i32 = 5;

/// The `why` of a row a hand session filed after its own [`self_check`].
const SELF_CHECK: &str = "self-check";

/// How many rows the shortlist shows, as many as triage shows its model.
const SHORTLIST_TOP: usize = 5;

/// A feature epic, `epic(<system>): <outcome>`, names one of the project's systems
/// (`project-stage-check <p> --list`, the check `epic_new` ran in bash). A standing epic
/// (`... to standard`) is the system's to file and passes here; [`self_check`] refuses it a hand
/// session. With no systems command (the second pass of [`add_via`]) there is nothing to check.
fn refuse_unknown_system(text: &str, canon: &str, systems: Option<&str>) -> Result<()> {
    let line = format!("- [ ] {text}");
    let Some(bin) = systems.filter(|_| crate::epics::is_epic(&line) && !standing_title(&line))
    else {
        return Ok(());
    };
    let area = projects::row_type_area(&line).map_or(String::new(), |(_, a)| a);
    let ids: Vec<String> = crate::standing::list(bin, canon)
        .map_err(|e| {
            anyhow::anyhow!("{e}: an epic names one of {canon}'s systems, so nothing was added")
        })?
        .into_iter()
        .map(|s| s.id)
        .collect();
    if ids.contains(&area) {
        return Ok(());
    }
    bail!(
        "epic({area}) names no system of {canon} (`{bin} {canon} --list`: {}), so nothing was added",
        if ids.is_empty() { "none".into() } else { ids.join(", ") }
    )
}

/// Is `line` an epic titled `... to standard`, the form a standing epic takes.
fn standing_title(line: &str) -> bool {
    projects::row_title(line)
        .to_lowercase()
        .ends_with(" to standard")
}

/// Triage's checks, run by a hand session on its own add before it writes; the twin refusals and
/// [`projects::row_findings`] ran already. The row carries a priority (triage's `priority_rule`
/// judges which), a hand session files no standing epic, and every open row on either lane that
/// [`similar`] lists for it is one the session named in `checked`. Ok(the ids shown) to write;
/// Err([`EXIT_SHORTLIST`]) with the shortlist printed when one is not named.
fn self_check(
    p: &Profile,
    name: &str,
    text: &str,
    row: &str,
    checked: &[String],
) -> Result<std::result::Result<Vec<String>, i32>> {
    if md::task_priority(row).is_none() {
        bail!("a row from a session carries #urgent, #high, #normal or #low, judged by triage's priority_rule (agentctl-inbox-triage), so nothing was added");
    }
    if crate::epics::is_epic(row) && standing_title(row) {
        bail!("a standing epic (`<system> to standard`) is filed by notes and project-stage-check, never by a session, so nothing was added");
    }
    let mut hits = Vec::new();
    for l in [Lane::Human, Lane::Agent] {
        let content = sheet_and_content(p, name, l)?
            .map(|(_, c)| c)
            .unwrap_or_default();
        hits.extend(
            similar(&content, text, SHORTLIST_TOP)
                .into_iter()
                .map(|(pct, r)| (pct, l, md::row_id(r), md::task_text(r))),
        );
    }
    hits.sort_by_key(|h| std::cmp::Reverse(h.0));
    hits.truncate(SHORTLIST_TOP);
    let shown: Vec<String> = hits.iter().filter_map(|h| h.2.clone()).collect();
    let missing: Vec<&String> = shown.iter().filter(|id| !checked.contains(id)).collect();
    if missing.is_empty() {
        return Ok(Ok(shown));
    }
    eprintln!(
        "similar open rows on {name}: read each, then join the one that is this work, or rerun with --checked {} when none is",
        shown.join(",")
    );
    for (pct, l, id, t) in &hits {
        println!("{}\t{pct}\t{}\t{t}", id.as_deref().unwrap_or("-"), l.name());
    }
    Ok(Err(EXIT_SHORTLIST))
}

/// The open row on `content` that `text` would duplicate: same [`md::task_key`], the key
/// `notes doctor` reports twins by, so a twin is refused at the writer instead of found later.
fn open_twin<'a>(content: &'a str, text: &str) -> Option<&'a str> {
    let key = md::task_key(&format!("- [ ] {text}"));
    sheet::open_rows(content)
        .into_iter()
        .map(|(_, l)| l)
        .find(|l| md::task_key(l) == key)
}

/// The open row on `content` that `text` nearly duplicates: the same type and title words
/// (hashtags, stamps and words under 3 letters aside, order ignored) of which at least
/// [`NEAR_DUP`] are shared, each title having 3 or more, and the same [`names`]: templated rows
/// that differ by one unit, watch, id or date (`agentctl@inbox-plan.service` and
/// `agentctl@nightly-measure.service` failed) are two rows however many words they share. The
/// area does not count: inbox-triage rewrites a filed row's area, so a filer that files the same
/// words again would miss its own row (research-pick's `research(roster):` row, re-scoped to
/// `research(notes):`, filed nightly). Deterministic, and strict on purpose: a refused near-dup
/// exits 3, which callers read as already filed, so a false twin would drop a row.
fn near_twin<'a>(content: &'a str, text: &str) -> Option<&'a str> {
    let line = format!("- [ ] {text}");
    let (kind, want) = title_words(&line);
    if want.len() < 3 {
        return None;
    }
    let own = names(&line);
    sheet::open_rows(content)
        .into_iter()
        .map(|(_, l)| l)
        .find(|l| {
            let (k, have) = title_words(l);
            row_type(&k) == row_type(&kind)
                && have.len() >= 3
                && share(&want, &have) >= NEAR_DUP
                && names(l) == own
        })
}

/// A row title's name-like tokens, lower-cased with edge punctuation trimmed: a word led by a
/// letter that also holds a digit, `_`, `@`, `/`, `:`, `-` or `.` (a unit, a watch, a lane, a
/// build), or an ISO date, so a dated template files one row per date. A token led by a digit or
/// a sign is a count or reading (`2 checks`, `7d 0.3`, `3/5`, `-3`), so a row whose numbers moved
/// is still the row.
fn names(line: &str) -> Words {
    projects::row_title(line)
        .to_lowercase()
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| ",;:.()[]\"'`".contains(c)))
        .filter(|w| {
            let date = w.len() == 10
                && w.bytes().enumerate().all(|(i, b)| match i {
                    4 | 7 => b == b'-',
                    _ => b.is_ascii_digit(),
                });
            let named = w.chars().next().is_some_and(char::is_alphabetic)
                && w.chars()
                    .any(|c| c.is_ascii_digit() || "_@/:-.".contains(c));
            date || named
        })
        .map(str::to_string)
        .collect()
}

/// The type half of a row's `type(area)`.
fn row_type(kind: &Option<(String, String)>) -> Option<&str> {
    kind.as_ref().map(|(t, _)| t.as_str())
}

type Words = std::collections::BTreeSet<String>;

/// A row line's `type(area)` and its title words, lower-cased and trimmed of punctuation, words
/// under 3 letters aside: the one reading [`near_twin`] and [`similar`] both score by.
fn title_words(line: &str) -> (Option<(String, String)>, Words) {
    let title = projects::row_title(line).to_lowercase();
    let set = title
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_ascii_alphanumeric()))
        .filter(|w| w.len() >= 3)
        .map(str::to_string)
        .collect();
    (projects::row_type_area(line), set)
}

/// The percent of both titles' words that the two sets share.
fn share(a: &Words, b: &Words) -> usize {
    let union = a.union(b).count();
    if union == 0 {
        return 0;
    }
    a.intersection(b).count() * 100 / union
}

/// The open rows of `content` closest to `text`, best first, at most `top`, each with its
/// [`share`] (under [`MIN_SIMILAR`] is no match: one shared `the` makes none). A tie goes to the row of the
/// same `type(area)`, then to the one higher on the sheet. The same share as [`near_twin`], so
/// every row the writer would refuse is listed; the writer also needs the same [`names`], and only
/// this tie-break reads the area.
fn similar<'a>(content: &'a str, text: &str, top: usize) -> Vec<(usize, &'a str)> {
    let (kind, want) = title_words(&format!("- [ ] {text}"));
    let mut hits: Vec<(usize, bool, &str)> = content
        .lines()
        .filter(|l| md::is_open_task(l))
        .filter_map(|l| {
            let (k, have) = title_words(l);
            let pct = share(&want, &have);
            (pct >= MIN_SIMILAR).then_some((pct, k == kind, l))
        })
        .collect();
    hits.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
    hits.into_iter().take(top).map(|(p, _, l)| (p, l)).collect()
}

/// `notes ptask <name> similar <text> [--top N] [--json]`: the open rows closest to `text`, TSV
/// `id<TAB>percent<TAB>row text` (`-` for a row with no id yet), or one JSON array of
/// `{id, percent, text}`. Reads only: the triager shows a model these few rows, not the board.
pub fn similar_rows(
    p: &Profile,
    name: &str,
    text: &str,
    top: usize,
    json: bool,
    lane: Lane,
) -> Result<i32> {
    let content = sheet_and_content(p, name, lane)?
        .map(|(_, c)| c)
        .unwrap_or_default();
    let rows = similar(&content, text, top);
    if json {
        let out: Vec<serde_json::Value> = rows
            .iter()
            .map(|(pct, l)| {
                serde_json::json!({
                    "id": md::row_id(l).unwrap_or_default(),
                    "percent": pct,
                    "text": md::task_text(l),
                })
            })
            .collect();
        println!("{}", serde_json::Value::Array(out));
        return Ok(0);
    }
    for (pct, l) in rows {
        println!(
            "{}\t{pct}\t{}",
            md::row_id(l).unwrap_or_else(|| "-".into()),
            md::task_text(l)
        );
    }
    Ok(0)
}

/// The least share, in percent, at which [`similar`] lists a row. Provisional: revisit when a
/// session line's real twin is missing from the rows it is shown.
const MIN_SIMILAR: usize = 20;

/// The share of title words, in percent of both titles' words, that makes a near-duplicate.
const NEAR_DUP: usize = 80;

/// The open row on `content` that lands the same PR as `text`, with that PR's number. Two
/// rows that land one PR are one piece of work whatever their type, area or wording
/// (unity-core-playground PR #2539 had four open rows, #2827 two). A row lands a PR when its
/// title says so ([`landed_pr`]); a row that only cites a PR, or is gated on one by a
/// `#pr/` tag (agent-queue's gate form), never matches. The qualifier must be equal too, so
/// `land platform PR #1594` and `land PR #1594` stay two rows: a false twin exits 3, which
/// callers read as already filed, and so drops a row.
fn pr_twin<'a>(content: &'a str, text: &str) -> Option<(&'a str, u64)> {
    let want = landed_pr(&format!("- [ ] {text}"))?;
    sheet::open_rows(content)
        .into_iter()
        .map(|(_, l)| l)
        .find(|l| landed_pr(l).as_ref() == Some(&want))
        .map(|l| (l, want.1))
}

/// The PR a row's title lands, `(qualifier, number)`: a landing verb (`land`, `re-land`,
/// `reland`, `re-gate`, `regate`), an optional `pr` or `train`, then `#N`, `PR#N`, `repo#N`,
/// `owner/repo#N`, or a bare number after `pr`. The qualifier is the ref's repo, or the one
/// word between the verb and `pr` (`land platform PR #1594`), lower-cased; None when neither.
fn landed_pr(line: &str) -> Option<(Option<String>, u64)> {
    const VERBS: [&str; 5] = ["land", "re-land", "reland", "re-gate", "regate"];
    let text = md::task_text(line).to_lowercase();
    let title = projects::row_prefix(&text).map_or(text.as_str(), |(_, _, t)| t);
    let words: Vec<&str> = title
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| matches!(c, '(' | ')' | ',' | ':' | ';' | '.')))
        .collect();
    let at = |j: usize| words.get(j).copied().unwrap_or("");
    words.iter().enumerate().find_map(|(i, w)| {
        if !VERBS.contains(w) {
            return None;
        }
        let mut j = i + 1;
        let mut qual = None;
        if at(j + 1) == "pr" && at(j) != "pr" {
            qual = Some(at(j).to_string());
            j += 1;
        }
        let pr = at(j) == "pr";
        if pr || at(j) == "train" {
            j += 1;
        }
        let w = at(j);
        if let Some((repo, n)) = w.split_once('#') {
            let repo = repo
                .rsplit('/')
                .next()
                .filter(|r| !r.is_empty() && *r != "pr");
            return Some((repo.map(str::to_string).or(qual), n.parse().ok()?));
        }
        pr.then(|| w.parse().ok().map(|n| (qual, n))).flatten()
    })
}

/// Put `block` at the end of the human sheet's `## Inbox` (creating the sheet and the section
/// as needed) and wake the triager. Lines already in the inbox are not written twice, so a
/// writer that stopped part way can run again. Returns the sheet.
pub(crate) fn inbox_put(
    p: &Profile,
    proj_dir: &Path,
    name: &str,
    block: &[String],
) -> Result<PathBuf> {
    let path = ensure_task_sheet(proj_dir, name)?;
    let content = fs::read_to_string(&path)?;
    let have: Vec<String> = sheet::inbox_lines(&content)
        .into_iter()
        .map(|l| l.raw)
        .collect();
    if block
        .first()
        .is_some_and(|b| have.contains(&b.trim_end().to_string()))
    {
        return Ok(path);
    }
    write_sheet(&path, &sheet::put_in_inbox(&content, block))?;
    inbox_changed(p);
    Ok(path)
}

/// The file every inbox writer touches, the event the triager's path unit waits on:
/// `<state_dir>/inbox.changed` (`~/.local/state/notes/inbox.changed` by default). A path
/// unit takes no glob, so one flag stands in for every sheet.
pub(crate) fn inbox_flag(p: &Profile) -> PathBuf {
    p.state_dir.join("inbox.changed")
}

/// Touch [`inbox_flag`]. Best effort: a missing state dir must not fail the write it follows.
pub(crate) fn inbox_changed(p: &Profile) {
    let flag = inbox_flag(p);
    if let Some(dir) = flag.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(&flag, format!("{}\n", chrono::Local::now().to_rfc3339()));
}

/// The tag a human's want carries on the agent board, put there by the writer.
const WANT_TAG: &str = "#requested";

/// What `ptask add` prints and exits with when it sent the row to the outbox instead of the
/// sheet: no caller reads it as a written row (0) or a twin (3).
pub const EXIT_INBOXED: i32 = 4;

/// The `--origin` of a plan's phases: a row its plan already approved, written directly.
const ORIGIN_PLAN: &str = "plan";

/// The triage runner: its new epics, like a hand session's, must name a listed system.
const TRIAGE: &str = "inbox-triage";

/// Who is writing a row, and so whether it goes on the sheet or to the outbox (`inbox-triage`
/// checks it against the board and files it, joins it to a twin or drops it). The class is the
/// environment's, never a flag's:
///
/// - a person (no session, queue item or runner) and a vouched direct filer (a plan's phases, a
///   name on `agent_direct_filers`) write the row now;
/// - a hand session (`CLAUDE_CODE_SESSION_ID` set, `AGENT_QUEUE_ITEM` and `AGENTCTL_NAME` unset,
///   one the human opened) runs triage's checks on its own add ([`self_check`]) and then writes it;
/// - an unattended writer (a queue item or a runner) leaves its row, on either lane, in the outbox.
///
/// A name is the process's, never the caller's word: `--origin <name>` counts only when it is
/// the runner's own `AGENTCTL_NAME` (with no session in the environment) or the parent process
/// runs a script of that basename, and `--origin plan` only when that parent is `agent-queue`
/// filing a plan's row (`AQ_ITEM_PLAN` or `AQ_FILE_ORIGIN` set, its `file_story`).
pub struct Writer {
    /// A queue item, a session or an agentctl runner is writing (the environment names one).
    automated: bool,
    /// A session the human opened by hand: no queue item or runner in the environment.
    hand: bool,
    /// The shortlist ids a hand session says it read and found to be other work (`--checked`).
    pub checked: Vec<String>,
    /// The vouched `--origin`, else the runner's own name; a session or queue item has none, so
    /// a runner name a session inherited can never make it a direct filer.
    name: Option<String>,
    /// An `--origin` this process could not vouch for, named when its row goes to the outbox.
    refused: Option<String>,
    /// A person at a terminal: no session, queue item, runner or `--origin` names the writer. A
    /// frozen release window takes such a writer's row through its interrupt lane; a command that
    /// files for itself (`Writer::human`, the playtest pass) is not one.
    person: bool,
    filers: Vec<String>,
}

impl Writer {
    /// This process's writer, from its environment and its parent's argv, holding the shortlist
    /// ids it says it checked (`ptask add --checked`).
    pub fn from_env(origin: Option<&str>, checked: Vec<String>) -> Writer {
        let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        let plan = env("AQ_ITEM_PLAN").is_some() || env("AQ_FILE_ORIGIN").is_some();
        let (item, session) = (env("AGENT_QUEUE_ITEM"), env("CLAUDE_CODE_SESSION_ID"));
        let runner = env("AGENTCTL_NAME");
        // Only an automated writer's --origin needs vouching, so only then is the parent read.
        let automated = item.is_some() || session.is_some() || runner.is_some();
        let parent = if origin.is_some() && automated {
            parent_argv()
        } else {
            Vec::new()
        };
        let filers = crate::config::agent_direct_filers();
        let checked = checked.into_iter().map(|c| c.trim().to_string()).collect();
        Writer {
            checked,
            ..Writer::of(item, session, runner, origin, &parent, plan, filers)
        }
    }

    /// [`Writer::from_env`] from its parts: the queue item, the session, the runner name, the
    /// `--origin`, the parent's argv and whether a plan's row is being filed.
    fn of(
        item: Option<String>,
        session: Option<String>,
        runner: Option<String>,
        origin: Option<&str>,
        parent: &[String],
        plan: bool,
        filers: Vec<String>,
    ) -> Writer {
        let origin = origin.map(str::trim).filter(|o| !o.is_empty());
        let unattended = item.is_some() || runner.is_some();
        let automated = unattended || session.is_some();
        let runner_name = runner
            .as_deref()
            .filter(|_| session.is_none() && item.is_none());
        let script = parent_script(parent);
        let vouched = |o: &str| match o {
            ORIGIN_PLAN => plan && script == Some(crate::ingest::ORIGIN_STORY),
            _ => runner_name == Some(o) || script == Some(o),
        };
        let (name, refused) = match origin {
            // A person's --origin is theirs to name: they file directly whatever it says.
            Some(o) if !automated || vouched(o) => (Some(o.to_string()), None),
            Some(o) => (runner_name.map(str::to_string), Some(o.to_string())),
            None => (runner_name.map(str::to_string), None),
        };
        Writer {
            automated,
            hand: automated && !unattended,
            checked: Vec::new(),
            person: !automated && origin.is_none(),
            name,
            refused,
            filers,
        }
    }

    /// A writer that always files on the sheet and is no interrupt: a command filing for itself
    /// (the playtest pass), not an agent write.
    pub fn human() -> Writer {
        Writer {
            automated: false,
            hand: false,
            checked: Vec::new(),
            person: false,
            name: None,
            refused: None,
            filers: Vec::new(),
        }
    }

    /// A person at a terminal: the one writer that may move, reprioritize or relock an open
    /// sprint's rows (`window::refuse_held`, `window::refuse_relock`).
    pub(crate) fn is_person(&self) -> bool {
        self.person
    }

    /// A plan's phases or a name on `agent_direct_filers`, vouched for by the process.
    fn direct(&self) -> bool {
        self.name
            .as_deref()
            .is_some_and(|n| n == ORIGIN_PLAN || self.filers.iter().any(|f| f == n))
    }

    /// An unattended writer that is no direct filer: its row goes to the outbox.
    fn inboxes(&self) -> bool {
        self.automated && !self.hand && !self.direct()
    }

    /// A hand session that is no direct filer: it runs [`self_check`] before it writes.
    fn self_checks(&self) -> bool {
        self.hand && !self.direct()
    }

    /// A hand session or inbox-triage: the writers whose new epic must name a listed system. A
    /// script that files an epic (credit-backfill, project-stage-check) carries a reviewed one.
    fn checks_epic_system(&self) -> bool {
        self.self_checks() || self.name.as_deref() == Some(TRIAGE)
    }
}

/// The parent process's argv: `/proc/<ppid>/cmdline` on Linux, `ps -o args=` elsewhere (macOS),
/// split on whitespace there. Empty when it cannot be read, which vouches for no `--origin`.
fn parent_argv() -> Vec<String> {
    let ppid = std::os::unix::process::parent_id();
    if let Ok(raw) = fs::read(format!("/proc/{ppid}/cmdline")) {
        return raw
            .split(|b| *b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
    }
    std::process::Command::new("ps")
        .args(["-o", "args=", "-p", &ppid.to_string()])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split_whitespace()
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// The basename of the script a parent argv runs: its first word for a script run by its own
/// path (or a binary), or the first non-flag word after an interpreter (`bash <script>`,
/// `bash -o pipefail <script>`, `python3 -I <script>`). An interpreter given `-c`, alone or in a
/// cluster like `-lc` (`-e` for perl, ruby and node), or no script, runs a string or a prompt, so
/// it names none.
fn parent_script(argv: &[String]) -> Option<&str> {
    fn base(s: &str) -> &str {
        s.rsplit('/').next().unwrap_or(s)
    }
    let first = base(argv.first()?);
    let shell = first.trim_start_matches('-');
    let python = shell.starts_with("python");
    let interp = python
        || matches!(
            shell,
            "sh" | "bash" | "zsh" | "dash" | "perl" | "ruby" | "node"
        );
    if !interp {
        return Some(first);
    }
    // The flag that runs its value as code: -e for perl, ruby and node, -c for the rest.
    let string_flag = if matches!(shell, "perl" | "ruby" | "node") {
        'e'
    } else {
        'c'
    };
    // Flags whose value is the next word: a shell's -o/-O option name, python's -W/-X.
    let takes_value = |a: &str| {
        let f = a.trim_start_matches(['-', '+']);
        if python {
            matches!(f, "W" | "X")
        } else {
            matches!(f, "o" | "O")
        }
    };
    let mut args = argv[1..].iter();
    while let Some(a) = args.next() {
        if !a.starts_with(['-', '+']) {
            return Some(base(a));
        }
        if !a.starts_with("--") && a[1..].contains(string_flag) {
            return None;
        }
        if takes_value(a) {
            args.next();
        }
    }
    None
}

/// A session's row as an outbox line: `#agent #p:<project> #from/<writer> <text>` plus its
/// details, which `inbox-triage` files, joins to a twin or drops. A human-lane row and an epic
/// (which lives on the human sheet) carry no `#agent`, and a `--want` channel rides as
/// `#want/<channel>`.
fn inbox_followup(
    p: &Profile,
    log: &Logger,
    name: &str,
    lane: Lane,
    text: &str,
    want: Option<&str>,
    details: &[String],
) -> Result<i32> {
    let board = lane == Lane::Agent && !crate::epics::is_epic(text);
    let agent = if board { "#agent " } else { "" };
    let want = want.map(|w| format!(" #want/{w}")).unwrap_or_default();
    let line = format!(
        "- [ ] {agent}#p:{name} #from/{}{want} {text}",
        crate::ingest::writer()
    );
    let mut block = vec![line];
    block.extend(md::detail_lines("", details));
    crate::outbox::append(p, log, &block)?;
    println!("inboxed: {}", block.join("\n"));
    Ok(EXIT_INBOXED)
}

/// `new` plus each tag of `old` (`#requested`, `#tier/3`) whose name, the part before `/`, `new`
/// does not set: the row's own tags outlive a rewrite of its words. Issue and PR refs
/// (`#1469`) are words, not tags, so they stay in the `was:` line only. The priority levels
/// share one name, so a new `#low` replaces the old `#high` rather than joining it.
fn carry_tags(old: &str, new: &str) -> String {
    let name = |t: &str| {
        if md::is_priority(t) {
            return "priority".to_string();
        }
        t.split('/').next().unwrap_or(t).to_string()
    };
    let set: Vec<String> = md::find_hashtags(new).iter().map(|t| name(t)).collect();
    md::find_hashtags(old)
        .into_iter()
        .filter(|t| t.starts_with(|c: char| c.is_ascii_lowercase()) && !set.contains(&name(t)))
        .fold(new.trim().to_string(), |out, t| {
            md::add_tag(&out, &format!("#{t}"))
        })
}

/// `new` plus the `#size/x` and `#pts/N` of `old` when `new` types neither: the sizing is the
/// row's estimate, not words, so a retext keeps it. Every other tag is exactly what `--text`
/// types, so leaving `#plan` out clears it. A `new` that types either sizing tag sets the
/// sizing itself.
fn carry_sizing(old: &str, new: &str) -> String {
    let sizing = |t: &String| t.starts_with("size/") || t.starts_with("pts/");
    if md::find_hashtags(new).iter().any(sizing) {
        return new.trim().to_string();
    }
    md::find_hashtags(old)
        .into_iter()
        .filter(sizing)
        .fold(new.trim().to_string(), |out, t| {
            md::add_tag(&out, &format!("#{t}"))
        })
}

/// The stamped rows for `texts` on `name`'s board, each followed by `details`: created tag,
/// default priority, the `to` tag, `marker` tokens and an id per row when the registry gives
/// the project a `code`. The ids run consecutively from [`next_id`], so rows written in one
/// call never share one.
fn new_rows(
    name: &str,
    proj_dir: &Path,
    texts: &[String],
    to: Option<V>,
    cur: Option<V>,
    marker: &[String],
    details: &[String],
) -> Result<Vec<String>> {
    let today = chrono::Local::now().date_naive();
    let code = project_map::Registry::load().and_then(|r| r.code(name));
    if code.is_none() {
        eprintln!(
            "(no id: '{name}' has no `code` in project-map.json trackers; the row is unaddressable by id)"
        );
    }
    if code.is_none() && texts.iter().any(|t| crate::epics::is_epic(t)) {
        bail!(
            "'{name}' has no `code` in project-map.json trackers, so an epic would get no id \
             for its stories' #of/<id> to name"
        );
    }
    let first = code.as_ref().map(|c| next_id_n(proj_dir, c));
    let mut block = Vec::new();
    for (k, text) in texts.iter().enumerate() {
        let mut line = md::stamp_line(
            &md::one_priority(&format!("- [ ] {}", text.trim())),
            today,
            today,
        );
        if let Some(v) = to {
            line = project_sweep::retag(&line, v, Some(v) == cur).0;
        }
        if let (Some(code), Some(n)) = (&code, first) {
            line = md::add_marker(&line, &format!("id:{code}-{}", n + k as u64));
        }
        for m in marker {
            line = md::add_marker(&line, m);
        }
        block.push(line);
        block.extend(md::brief_lines("", details));
    }
    Ok(block)
}

/// The marker token on a row the triager filed today: `filed:YYYY-MM-DD`. The "filed today"
/// views read it back with [`filed_on`].
pub(crate) fn filed_token(day: chrono::NaiveDate) -> String {
    format!("filed:{}", day.format("%Y-%m-%d"))
}

/// The day a row was filed from an inbox, from its `filed:` marker token.
pub(crate) fn filed_on(line: &str) -> Option<String> {
    md::marker_token(line, "filed:")
        .filter(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").is_ok())
        .map(str::to_string)
}

/// Turn the lists waiting in this sheet's `## Inbox` into one line per ask
/// (`sheet::split_lists`), the first step of a triage sweep.
pub fn inbox_split(p: &Profile, name: &str, lane: Lane) -> Result<i32> {
    let Some((path, content)) = sheet_and_content(p, name, lane)? else {
        return Ok(0);
    };
    let (out, lists) = sheet::split_lists(&content, sheet::INBOX);
    if out != content {
        write_sheet(&path, &out)?;
    }
    crate::ingest::record_splits(p, name, &lists);
    Ok(0)
}

/// `notes ptask <name> inbox [--json]` - the lines waiting in `## Inbox`, oldest first:
/// TSV `path<TAB>line<TAB>text`, or one JSON array of `{line, raw, text, details, typed}`,
/// `typed` when the text already reads `type(area): title`.
pub fn inbox(p: &Profile, name: &str, json: bool, lane: Lane) -> Result<i32> {
    let (path, lines) = match sheet_and_content(p, name, lane)? {
        Some((path, content)) => (path, sheet::inbox_lines(&content)),
        None => (PathBuf::new(), Vec::new()),
    };
    if json {
        let rows: Vec<serde_json::Value> = lines
            .iter()
            .map(|l| {
                serde_json::json!({
                    "line": l.line, "raw": l.raw, "text": l.text, "details": l.details,
                    "typed": projects::is_typed(&l.text),
                })
            })
            .collect();
        println!("{}", serde_json::Value::Array(rows));
        return Ok(0);
    }
    for l in &lines {
        println!("{}\t{}\t{}", path.display(), l.line, l.text);
    }
    Ok(0)
}

/// What [`file`] does with an inbox line, and on which board: `project`'s (default the
/// line's own) in `lane`.
pub(crate) struct Filing {
    pub project: Option<String>,
    pub lane: Lane,
    /// The channel the line came in by: its agent-lane rows get `#requested`.
    pub want: Option<&'static str>,
    /// How the sweep decided it (`--why`), on the ingest event.
    pub why: Option<String>,
    pub how: How,
}

/// The two ways an inbox line leaves.
pub(crate) enum How {
    /// File it as these typed rows (more than one splits a pile; none files a typed line as
    /// written), aimed at `to`, each with `details` under it.
    Rows {
        texts: Vec<String>,
        to: Option<String>,
        details: Vec<String>,
    },
    /// It duplicates this open row: its words join that row as a detail line.
    Dup(String),
    /// It asks for no row: the line leaves the inbox, recorded as `dropped` with the why.
    Skip,
}

/// The inbox line `pick` names: by words in its text, or byte for byte with `--exact`.
fn inbox_hit(pick: &Pick, l: &sheet::InboxLine) -> bool {
    match pick {
        Pick::Words(q) | Pick::Id(q) => l.text.to_lowercase().contains(q.as_str()),
        Pick::Exact(raw) => l.raw == *raw,
    }
}

/// `notes ptask <name> file <query> (--as "<type(area): title>"... | --dup <id>)` - take the
/// first inbox line matching `<query>` off `## Inbox` and onto a board, in one write per
/// sheet. `--as` files it as typed rows ([`new_rows`] stamps them, plus `filed:<today>`),
/// on `--project`'s board and in `--lane`'s sheet when given (an `#agent` word in the line picks
/// the agent sheet and stays off the rows); no `--as` files a line that is
/// typed already as written; `--dup` adds it to an open row. The human's words stay as a
/// `was: <words>` detail line (none when filed as written), with the line's own detail lines
/// after it. A row the grammar flags (a retired priority, two priorities, a retired tag) is
/// refused. This is the triager's one write path: it never edits a sheet.
///
/// Every refusal comes before the first write. When the line moves to another sheet, that
/// sheet is written first, so a failed second write leaves the line on both sheets (seen,
/// filed twice) and never on neither. The one write that may come before them is a standing
/// epic a row links to ([`link_standing`]), filed once every refusal has passed.
pub(crate) fn file(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    how: &Filing,
    lane: Lane,
) -> Result<i32> {
    file_via(
        p,
        log,
        name,
        pick,
        how,
        lane,
        Some(crate::standing::SYSTEMS_BIN),
        None,
    )
}

/// [`file`] with the systems command named (a test points it at a stub). The second pass,
/// after [`link_standing`] wrote an epic, gets no command and the rows as `linked`, so it
/// re-reads every sheet the epic may have changed and files them as they are.
#[allow(clippy::too_many_arguments)]
fn file_via(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    how: &Filing,
    lane: Lane,
    systems: Option<&str>,
    linked: Option<Vec<String>>,
) -> Result<i32> {
    let Some((src, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet, so no inbox");
    };
    let Some((rest, line)) = sheet::take_inbox(&content, |l| inbox_hit(pick, l)) else {
        eprintln!("no inbox line matches '{pick}' in {name}");
        return Ok(1);
    };
    if matches!(how.how, How::Skip) {
        write_sheet(&src, &rest)?;
        let mut ev = crate::ingest::Event::new("dropped", name, "", &line.text);
        ev.why = crate::ingest::set(how.why.as_deref());
        crate::ingest::record(p, &ev);
        log.info("ptask", &format!("dropped from {name}'s inbox"));
        println!("dropped {}", line.text);
        return Ok(0);
    }
    // The human's words, unless the line is filed as written.
    let as_is = matches!(&how.how, How::Rows { texts, .. } if texts.is_empty());
    let mut details = if as_is {
        Vec::new()
    } else {
        vec![format!("was: {}", line.text)]
    };
    details.extend(line.details.iter().cloned());
    // An `#agent` word files the line's rows on the agent board, and stays off them.
    let to_agent = matches!(how.how, How::Rows { .. }) && md::agent_tag(&line.text);
    let dest_lane = if to_agent { Lane::Agent } else { how.lane };
    let dest_name = how.project.as_deref().unwrap_or(name);
    let dest_proj = projects::project_dir(p, dest_name)?;
    let dest_dir = dest_lane.dir(&dest_proj);
    let dest = ensure_lane_sheet(p, &dest_proj, dest_name, dest_lane)?;
    let same = same_sheet(&src, &dest);
    let base = if same {
        rest.clone()
    } else {
        fs::read_to_string(&dest)?
    };
    let (new_dest, written) = match &how.how {
        How::Rows {
            texts,
            to,
            details: extra,
        } => {
            let texts: Vec<String> = if let Some(l) = &linked {
                l.clone()
            } else if as_is {
                if !projects::is_typed(&line.text) {
                    bail!("'{}' is not typed yet, so file needs --as \"<type(area): title>\" or --dup <id>", line.text);
                }
                vec![line.text.clone()]
            } else {
                texts.clone()
            };
            let texts: Vec<String> = texts.iter().map(|t| md::without_agent_tag(t)).collect();
            if let Some(bad) = texts.iter().find(|t| !projects::is_typed(t)) {
                bail!("'{bad}' is not `type(area): title` (README \"The task row\"), so nothing was filed");
            }
            let to = to.as_deref().map(parse_to).transpose()?;
            let cur = version_in(&dest_dir, &base);
            if let Some(v) = to {
                refuse_behind(v, cur)?;
            }
            details.extend(extra.iter().cloned());
            refuse_epic_on_board(
                dest_lane,
                &texts.iter().map(String::as_str).collect::<Vec<_>>(),
            )?;
            let today = chrono::Local::now().date_naive();
            let mut block = new_rows(
                dest_name,
                &dest_proj,
                &texts,
                to,
                cur,
                &[filed_token(today)],
                &details,
            )?;
            if how.want.is_some() && dest_lane == Lane::Agent {
                for l in block.iter_mut().filter(|l| md::is_open_task(l)) {
                    *l = md::add_tag(l, WANT_TAG);
                }
            }
            if let Some(why) = projects::row_findings(&block.join("\n"), false).first() {
                bail!("{why}, so nothing was filed");
            }
            if let Some(bin) = systems {
                if let Some(l) = link_standing(p, log, dest_name, &dest_proj, &texts, bin)? {
                    return file_via(p, log, name, pick, how, lane, None, Some(l));
                }
            }
            // A frozen release window takes these rows only through its interrupt lane: the
            // human's own words from their sheet's inbox, or a want by a human channel, are one.
            let interrupt = (lane == Lane::Human && !md::agent_tag(&line.text))
                || how.want.is_some_and(crate::window::human_channel);
            let block = crate::window::admit(&dest_proj, cur, block, interrupt);
            (md::insert_under_heading(&base, sheet::TASKS, &block), block)
        }
        How::Dup(id) => {
            if !md::is_row_id(id) {
                bail!("--dup takes the id of an open row (like ar-142), not '{id}'");
            }
            let hit = Pick::Id(id.clone());
            let Some(new) = md::append_details(&base, sheet::TASKS, |l| hit.hits(l), &details)
            else {
                bail!(
                    "no open row {id} on {}, so nothing was filed",
                    dest.display()
                );
            };
            (new, details.iter().map(|d| format!("  {d}")).collect())
        }
        How::Skip => unreachable!("a skip returns before a destination is chosen"),
    };
    write_sheet(&dest, &new_dest)?;
    note_ids(&dest_proj, &written)?;
    if !same {
        write_sheet(&src, &rest).map_err(|e| {
            anyhow::anyhow!(
                "{e}\n  the line was FILED on {} but is still in {}'s inbox - file it again with --dup",
                dest.display(),
                src.display()
            )
        })?;
    }
    log.info(
        "ptask",
        &format!(
            "filed from {}'s inbox to {} ({dest_name})",
            name,
            dest.display()
        ),
    );
    let mut ev = crate::ingest::Event::new(
        if matches!(how.how, How::Dup(_)) {
            "dup"
        } else {
            "filed"
        },
        name,
        dest_name,
        &line.text,
    );
    ev.lane = dest_lane.name().into();
    ev.want = how.want.map(str::to_string);
    ev.why = crate::ingest::set(how.why.as_deref());
    ev.id = match &how.how {
        How::Dup(id) => Some(id.clone()),
        How::Skip => None,
        How::Rows { .. } => written
            .iter()
            .find_map(|l| md::marker_token(l, "id:"))
            .map(str::to_string),
    };
    if matches!(how.how, How::Rows { .. }) {
        ev.row = written
            .iter()
            .find(|l| md::row_id(l).is_some())
            .map(|l| crate::ingest::row_words(l));
    }
    crate::ingest::record(p, &ev);
    println!("filed {}", line.text);
    for l in &written {
        println!("  {l}");
    }
    Ok(0)
}

/// `texts` with each leaf that has no `#of/`, and whose area is one of `name`'s systems
/// ([`crate::standing`]), tagged `#of/<id>` of that system's open standing epic. An epic the
/// human sheet lacks is filed there first, stamped and id'd like any row, and reported on stderr
/// (stdout is the row a caller reads its id from). None when no text changes: no leaf wants
/// a link, the project has no row code (an epic needs an id), or the system list is not to be
/// had, in which case the rows are written unlinked.
fn link_standing(
    p: &Profile,
    log: &Logger,
    name: &str,
    proj_dir: &Path,
    texts: &[String],
    bin: &str,
) -> Result<Option<Vec<String>>> {
    let areas: Vec<Option<String>> = texts
        .iter()
        .map(|t| crate::standing::wants_link(t))
        .collect();
    if areas.iter().all(Option::is_none)
        || project_map::Registry::load()
            .and_then(|r| r.code(name))
            .is_none()
    {
        return Ok(None);
    }
    // The dir's name is the canonical project name, the one the systems list is keyed by.
    let canon = proj_dir
        .file_name()
        .map_or(name.into(), |n| n.to_string_lossy());
    let Some(systems) = crate::standing::systems(bin, &canon) else {
        return Ok(None);
    };
    let mut out = texts.to_vec();
    let mut changed = false;
    for (text, area) in out.iter_mut().zip(&areas) {
        let Some(system) = area
            .as_deref()
            .and_then(|a| crate::standing::system_of(&systems, a))
        else {
            continue;
        };
        let sheet = ensure_lane_sheet(p, proj_dir, name, Lane::Human)?;
        let content = fs::read_to_string(&sheet)?;
        let id = match crate::standing::find(&content, system) {
            Some(id) => id,
            None => {
                let cur = version_in(proj_dir, &content);
                let block = new_rows(
                    name,
                    proj_dir,
                    &[crate::standing::title(system)],
                    None,
                    cur,
                    &[],
                    &[],
                )?;
                let id = md::row_id(&block[0]).context("a new standing epic got no id")?;
                write_sheet(
                    &sheet,
                    &md::insert_under_heading(&content, sheet::TASKS, &block),
                )?;
                note_ids(proj_dir, &block)?;
                log.info(
                    "ptask",
                    &format!("standing epic {id} filed on {} ({name})", sheet.display()),
                );
                crate::ingest::record(
                    p,
                    &crate::ingest::Event::row("added", name, "", Lane::Human.name(), &block[0]),
                );
                // No marker comment here: a caller merging stderr reads the first `id:` as its row's.
                eprintln!(
                    "standing epic {id} filed on {}: {}",
                    sheet.display(),
                    crate::standing::title(system)
                );
                id
            }
        };
        *text = md::add_tag(text, &format!("#of/{id}"));
        changed = true;
    }
    Ok(changed.then_some(out))
}

/// The next row id for a project: `<code>-<n>`, `n` one past the highest `id:<code>-N` on any
/// `.md` file under its dir (both lanes, playtest and `versions/`) and in its [`IDS`] file. A
/// dropped row keeps its id on the sheet and an archived one keeps it in `versions/`; a row
/// moved to another project, or deleted by hand, takes its id away, and [`IDS`] remembers it,
/// so an id is never reused.
pub(crate) fn next_id(proj_dir: &Path, code: &str) -> String {
    format!("{code}-{}", next_id_n(proj_dir, code))
}

/// The project's id high-water file, `<project>/.ids`: one `id:<code>-<n>` line per code,
/// the highest id it ever minted. Written by every verb that mints one ([`note_ids`]); synced
/// with the vault like the sheets.
pub(crate) const IDS: &str = ".ids";

/// Raise [`IDS`] to the highest id in `lines`, per code, when that is past what it holds.
/// Called after the sheet write, under [`lock`], so a failed write leaves a gap, never a reuse.
fn note_ids(proj_dir: &Path, lines: &[String]) -> Result<()> {
    let split = |id: &str| {
        id.rsplit_once('-')
            .and_then(|(c, n)| Some((c.to_string(), n.parse::<u64>().ok()?)))
    };
    let path = proj_dir.join(IDS);
    let mut top: std::collections::BTreeMap<String, u64> = fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().strip_prefix("id:").and_then(split))
        .collect();
    let mut raised = false;
    for (code, n) in lines
        .iter()
        .filter_map(|l| md::row_id(l))
        .filter_map(|id| split(&id))
    {
        let held = top.entry(code).or_insert(0);
        if n > *held {
            *held = n;
            raised = true;
        }
    }
    if raised {
        let body: String = top.iter().map(|(c, n)| format!("id:{c}-{n}\n")).collect();
        md::write_atomic(&path, &body)?;
    }
    Ok(())
}

/// The write lock every `notes ptask` writer holds from its read to its write, and around id
/// minting: `<state_dir>/ptask.lock`. Without it two writers (a dispatch pass and a session)
/// read the same sheet, and the second write loses the first one's row, or both mint one id.
pub(crate) fn lock(p: &Profile) -> Result<md::FileLock> {
    md::lock_file(&p.state_dir.join("ptask.lock"))
}

/// The number half of [`next_id`].
fn next_id_n(proj_dir: &Path, code: &str) -> u64 {
    let needle = format!("id:{code}-");
    let mut max = 0u64;
    let mut stack = vec![proj_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for e in entries.flatten() {
            let path = e.path();
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                stack.push(path);
            } else if path.extension().is_some_and(|x| x == "md")
                || path.file_name().is_some_and(|n| n == IDS)
            {
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                for (i, _) in text.match_indices(&needle) {
                    let digits: String = text[i + needle.len()..]
                        .chars()
                        .take_while(char::is_ascii_digit)
                        .collect();
                    max = max.max(digits.parse().unwrap_or(0));
                }
            }
        }
    }
    max + 1
}

/// `notes ptask <name> move <query> --to vX.Y.Z` - aim the first open task matching `<query>`
/// at `<ver>`. The row stays where it is; only its tag changes.
///
/// The verb that splits a pile into a roadmap, and the one the release gate points at: a
/// version that still has open work does not close, so either finish the task or say
/// explicitly which version it belongs to instead.
pub fn move_task(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    to: &str,
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    let proj = projects::project_dir(p, name)?;
    let dir = lane.dir(&proj);
    let Some(path) = task_sheet(&dir) else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    let content = fs::read_to_string(&path)?;
    let to = parse_to(to)?;
    let cur = version_in(&dir, &content);
    refuse_behind(to, cur)?;

    let Some((new, was, line)) = retarget(&content, pick, to, cur) else {
        eprintln!(
            "no open task matches '{pick}' outside {} in {name}",
            projects::fmt_version(to)
        );
        return Ok(1);
    };
    if Some(to) != cur {
        crate::window::refuse_held(&proj, cur, &was, writer, "moving")?;
    }
    write_sheet(&path, &new)?;
    let to_s = projects::fmt_version(to);
    log.info(
        "ptask",
        &format!("moved to {to_s} in {} ({name})", path.display()),
    );
    let mut ev = crate::ingest::Event::row("placed", name, "", lane.name(), &line);
    ev.why = Some(to_s.clone());
    crate::ingest::record(p, &ev);
    println!("moved {}\n  -> {to_s}", line.trim());
    Ok(0)
}

/// Pure core of the same-sheet `move`: retag the first open row matching `pick` that does not
/// already belong to `to`. Returns `(new_content, line_as_it_was, retagged_line)`, or `None` when nothing
/// outside the target matches, so a move onto its own version is a clear no-op. An untagged
/// epic belongs to no release ([`crate::epics::in_some_version`]), so aiming it at the open
/// version by id or exact line tags it; a words pick still skips it there, so a loose query
/// cannot tag an epic above the row it meant.
fn retarget(content: &str, pick: &Pick, to: V, cur: Option<V>) -> Option<(String, String, String)> {
    let aim = |l: &str| project_sweep::retag(l.trim_end(), to, Some(to) == cur).0;
    let named = !matches!(pick, Pick::Words(_));
    let (new, matched) = md::edit_first_in_section(
        content,
        sheet::TASKS,
        |l| {
            pick.hits(l)
                && (sheet::version_of(l, cur) != Some(to)
                    || (named && !crate::epics::in_some_version(l)))
        },
        |l| Some(aim(l)),
    )?;
    let aimed = aim(&matched);
    Some((new, matched, aimed))
}

/// The first open row matching `pick`, in sheet order.
fn find_open(content: &str, pick: &Pick) -> Option<String> {
    sheet::open_rows(content)
        .into_iter()
        .find(|(_, l)| pick.hits(l))
        .map(|(_, l)| l.trim_end().to_string())
}

/// `notes ptask <src> move <query> --project <dest> [--to vX.Y.Z]` - move the first open
/// row matching `<query>` off SRC's sheet and onto DEST's, aimed at the release `--to` names.
/// How a catch-all sheet gets split into per-project ones without hand-editing.
///
/// DEST resolves through `projects::project_dir` like every other name here, so it may live
/// in another profile. `--agent` works because both ends go through the same `lane_dir`:
/// agent sheet to agent sheet.
#[allow(clippy::too_many_arguments)]
pub fn move_to_project(
    p: &Profile,
    log: &Logger,
    src: &str,
    dest: &str,
    pick: &Pick,
    to: Option<&str>,
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    let src_dir = lane_dir(p, src, lane)?;
    let dest_dir = lane_dir(p, dest, lane)?;
    let Some(src_sheet) = task_sheet(&src_dir) else {
        bail!("'{src}' has no task sheet yet - nothing to move");
    };
    let Some(dest_sheet) = task_sheet(&dest_dir) else {
        let flag = if lane == Lane::Agent { " --agent" } else { "" };
        bail!("'{dest}' has no task sheet with a `## Tasks` to move into - add one with `notes ptask {dest}{flag} add \"...\"`");
    };
    // A move writes a row on DEST as an add would, so it is refused an epic on the board too,
    // and it takes the row out of SRC's open sprint.
    let src_content = fs::read_to_string(&src_sheet)?;
    if let Some(row) = find_open(&src_content, pick) {
        if lane == Lane::Agent {
            refuse_epic_on_board(lane, &[&row])?;
        }
        let what = format!("moving to {dest}");
        crate::window::refuse_held(
            &projects::project_dir(p, src)?,
            version_in(&src_dir, &src_content),
            &row,
            writer,
            &what,
        )?;
    }
    let held = row_ids(&projects::project_dir(p, dest)?);
    let Some(moved) = transfer(&src_sheet, &dest_sheet, pick, to, &held)? else {
        eprintln!("no open task matches '{pick}' in {src}");
        return Ok(1);
    };
    log.info(
        "ptask",
        &format!(
            "moved from {} ({src}) to {} ({dest})",
            src_sheet.display(),
            dest_sheet.display()
        ),
    );
    crate::ingest::record(
        p,
        &crate::ingest::Event::row("rehomed", src, dest, lane.name(), &moved.line),
    );
    println!("moved {}\n  {src} -> {dest}", moved.line.trim());
    if let Some(id) = &moved.unlinked {
        // Kept in the journal log, so a child moved ahead of its epic can be linked again.
        let why = format!("dropped #of/{id}: it names no row in {dest}");
        log.info("ptask", &format!("{} {why}", moved.line.trim()));
        println!("  {why}");
    }
    Ok(0)
}

/// The ids of every row a project holds: its human sheet, its agent board and both lanes'
/// `versions/` notes, the rows `notes doctor`'s tree (`epics::Index::of`) reads, so an `#of/`
/// naming one of them is never dangling there.
fn row_ids(dir: &Path) -> HashSet<String> {
    let mut files = Vec::new();
    for lane in [dir.to_path_buf(), projects::agent_dir(dir)] {
        files.extend(task_sheet(&lane));
        files.extend(
            projects::version_notes(&lane.join("versions"))
                .into_iter()
                .map(|(_, p)| p),
        );
    }
    files
        .iter()
        .filter_map(|f| fs::read_to_string(f).ok())
        .flat_map(|t| t.lines().filter_map(md::row_id).collect::<Vec<_>>())
        .collect()
}

/// What a cross-project move did: both sheets' new text and the row as it landed.
#[derive(Debug)]
struct Lifted {
    src: String,
    dest: String,
    line: String,
    /// The `#of/` parent the row lost: it names no row in the destination.
    unlinked: Option<String>,
}

/// File half of `move_to_project`: read both sheets, compute both edits, then write.
///
/// Every refusal happens before the first write. The DEST is written first and the SRC
/// second, because if the second write fails the row then exists on BOTH sheets (a
/// duplicate you can see and `rm`) rather than on NEITHER (a task silently gone).
fn transfer(
    src_sheet: &Path,
    dest_sheet: &Path,
    pick: &Pick,
    to: Option<&str>,
    held: &HashSet<String>,
) -> Result<Option<Lifted>> {
    if same_sheet(src_sheet, dest_sheet) {
        bail!(
            "source and destination are the same sheet - use `move --to <VERSION>` to change release"
        );
    }
    let src = fs::read_to_string(src_sheet)?;
    let dest = fs::read_to_string(dest_sheet)?;
    let to = to.map(parse_to).transpose()?;
    let dest_cur = dest_sheet.parent().and_then(open_version_for);
    if let Some(v) = to {
        refuse_behind(v, dest_cur)?;
    }
    let Some(moved) = lift_into(&src, &dest, pick, to, dest_cur, held)? else {
        return Ok(None);
    };
    write_sheet(dest_sheet, &moved.dest)?;
    write_sheet(src_sheet, &moved.src).map_err(|e| {
        anyhow::anyhow!(
            "{e}\n  the row was ADDED to {} but not removed from {} - `rm` it there",
            dest_sheet.display(),
            src_sheet.display()
        )
    })?;
    Ok(Some(moved))
}

/// Pure core of a cross-project move: the first open row matching `query` in `src`, cut from
/// `src` and inserted into `dest`'s `## Tasks`. The source's `#v` tag means nothing on another
/// project's roadmap, so it goes unless `to` names one, and so does an `#of/` naming no row
/// in `held` (the destination's ids): it would dangle there, and `--link` files the row under
/// one of that project's epics. `None` on no match.
fn lift_into(
    src: &str,
    dest: &str,
    pick: &Pick,
    to: Option<V>,
    dest_cur: Option<V>,
    held: &HashSet<String>,
) -> Result<Option<Lifted>> {
    // Refuse before looking at the source: a dest with no section to land in is the refusal,
    // whether or not the query would have matched.
    if !sheet::has_tasks(dest) {
        bail!("no `## Tasks` section on the destination sheet");
    }
    // The row's detail lines and child rows go with it: left behind, they would read as the
    // row above's.
    let Some((cut, line, block)) =
        md::cut_first_block_in_section(src, sheet::TASKS, |l| pick.hits(l))
    else {
        return Ok(None);
    };
    let line = line.trim_end().trim_start();
    let line = match to {
        Some(v) => project_sweep::retag(line, v, Some(v) == dest_cur).0,
        None => md::split_version(line).0,
    };
    let unlinked = crate::epics::parent_of(&line).filter(|id| !held.contains(id));
    let line = match &unlinked {
        Some(id) => md::drop_tag(&line, &format!("#of/{id}")),
        None => line,
    };
    let mut landed = vec![line.clone()];
    landed.extend(block);
    let grown = md::insert_under_heading(dest, sheet::TASKS, &landed);
    Ok(Some(Lifted {
        src: cut,
        dest: grown,
        line,
        unlinked,
    }))
}

/// `notes ptask <name> promote|demote <query>` - step the first matching task one release
/// sooner or later, the way `<leader>tP`/`tp` steps a priority.
///
/// `move --to vX.Y.Z` needs an absolute version typed out; a relative step costs nothing to
/// reach for, which is what makes splitting a pile across releases something you actually do.
/// The rungs are the open version and every release an open row is aimed at.
///
/// `promote` clamps at the open version and exits NON-ZERO there: the cockpit drives these
/// through fzf `execute-silent`, which discards stdout, so a zero exit would render "there is
/// nothing sooner" as silence.
pub fn step(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    dir: i32,
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    let dir_word = if dir < 0 { "promote" } else { "demote" };
    let proj = projects::project_dir(p, name)?;
    let dir_proj = lane.dir(&proj);
    let Some(path) = task_sheet(&dir_proj) else {
        bail!("'{name}' has no task sheet yet - add one with `notes ptask {name} add \"...\"`");
    };
    let content = fs::read_to_string(&path)?;
    let cur = version_in(&dir_proj, &content)
        .ok_or_else(|| anyhow::anyhow!("{name}'s sheet has no `Version:` line"))?;
    let Some(line) = find_open(&content, pick) else {
        eprintln!("no open task matches '{pick}' in {name}");
        return Ok(1);
    };
    let at = sheet::version_of(&line, Some(cur)).unwrap_or(cur);
    let ladder = sheet::later_versions(&content, Some(cur));

    let Some(to) = project_sweep::step_version(cur, &ladder, at, dir) else {
        eprintln!(
            "'{}' is already in {} - nothing sooner than the open version",
            md::task_text(&line),
            projects::fmt_version(cur)
        );
        return Ok(1);
    };
    if to != cur {
        crate::window::refuse_held(&proj, Some(cur), &line, writer, &format!("{dir_word} of"))?;
    }

    let (retagged, note) = project_sweep::retag(&line, to, to == cur);
    let Some((new, _)) =
        md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), |_| Some(retagged))
    else {
        bail!("could not retag '{pick}'");
    };
    write_sheet(&path, &new)?;
    let (at_s, to_s) = (projects::fmt_version(at), projects::fmt_version(to));
    log.info(
        "ptask",
        &format!("{dir_word}d to {to_s} in {} ({name})", path.display()),
    );
    let mut ev = crate::ingest::Event::row("placed", name, "", lane.name(), &line);
    ev.why = Some(format!("{at_s} -> {to_s}"));
    crate::ingest::record(p, &ev);
    println!("{} {}", dir_word, md::task_text(&line));
    println!("  {at_s} -> {to_s}");
    if let Some(n) = note {
        println!("  {n}");
    }
    Ok(0)
}

/// `notes ptask <name> done <query> (--proof <ref> | --unverified "<why>")` — check off the
/// first open task matching `<query>`, and record WHY it counts as done.
///
/// Done needs evidence. A bare `done` is rejected because "closed" and "finished" drifted
/// apart everywhere they were allowed to: the roll gate above only means something if the
/// checkboxes it counts mean something. Two doors, deliberately:
///
/// - `--proof <ref>` — something checkable later: `pr:1142`, `run:<id>`, a URL. Stamped
///   into the line's marker comment beside any existing `id:`/`ask:` key.
/// - `--unverified "<why>"` — no checkable artifact exists. Also stamped, and visibly so,
///   because the failure mode of a proof field is not people lying in it, it is people
///   leaving it blank until it means nothing. The manual walk has the same
///   instinct: `n/a - <why>` mandatory rather than blank.
///
/// Either way the stamp stays on the row, which is what turns a pile of ticked boxes into an
/// evidence trail somebody can audit.
#[allow(clippy::too_many_arguments)]
pub fn done(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    proof: Option<&str>,
    unverified: Option<&str>,
    on: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let stamp = proof_stamp(proof, unverified)?;
    let day = close_day(on)?;
    refuse_open_children(p, name, pick, lane, "finish")?;
    if proof.is_some() {
        refuse_landed_as_proof(p, name, pick, lane, &stamp)?;
    }
    let on = done_token(day);
    Ok(edit(p, log, name, pick, "done", Some(&stamp), lane, |l| {
        let ticked = md::add_marker(&closed(l), &on);
        Some(md::add_marker(&ticked, &stamp))
    })?
    .0)
}

/// The day a close is stamped with: `--on <day>`, else today. A future day is refused: a close
/// is something that happened, and the pace counts read a later day as not yet closed.
fn close_day(on: Option<&str>) -> Result<chrono::NaiveDate> {
    let today = chrono::Local::now().date_naive();
    let Some(raw) = on else { return Ok(today) };
    let day = chrono::NaiveDate::parse_from_str(raw.trim(), "%Y-%m-%d")
        .map_err(|_| anyhow::anyhow!("--on takes a day as YYYY-MM-DD, not '{raw}'"))?;
    if day > today {
        bail!("--on {raw} is in the future");
    }
    Ok(day)
}

/// `notes ptask <name> redate --on <day> <id>` - move a closed row's `done:` day. `done` takes
/// the day itself now; this is for a row an earlier writer stamped with the wrong one (the
/// credit backfill stamped its apply day). Only a closed row that already carries a `done:`
/// day is touched, and only that day changes.
pub fn redate(
    p: &Profile,
    log: &Logger,
    name: &str,
    id: &str,
    on: &str,
    dry_run: bool,
    lane: Lane,
) -> Result<i32> {
    let day = close_day(Some(on))?;
    if !md::is_row_id(id) {
        bail!("redate takes a row id such as ar-142, not '{id}'");
    }
    let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet yet");
    };
    let hit = |l: &str| {
        l.trim_start().starts_with("- [x]")
            && md::row_id(l).as_deref() == Some(id)
            && done_on(l).is_some()
    };
    let Some((new, matched)) = md::edit_first_in_section(&content, sheet::TASKS, hit, |l| {
        // Only inside the trailing marker: a title that quotes `done:<day>` stays as written.
        let old = md::marker_token(l, "done:")?;
        let at = l.rfind("<!--")?;
        let marker = l[at..].replacen(&format!("done:{old}"), &done_token(day), 1);
        Some(format!("{}{marker}", &l[..at]))
    }) else {
        eprintln!("no closed task with id {id} and a done day in {name}");
        return Ok(1);
    };
    if dry_run {
        let old = done_on(&matched).map(|d| d.to_string()).unwrap_or_default();
        println!("{id}\t{old}\t{day}");
        return Ok(0);
    }
    if new == content {
        println!("unchanged {}", matched.trim());
        return Ok(0);
    }
    write_sheet(&sheet, &new)?;
    log.info("ptask", &format!("redated in {} ({name})", sheet.display()));
    println!("redated {id} to {day}");
    Ok(0)
}

/// `notes ptask <name> reopen <id> --why "<why>"` - undo a false close: the closed row with that
/// id goes back to todo (`[ ]`), and what `done` or `drop` stamped on its marker comes off, so a
/// proof that was never its work stops reading as delivery (2026-11-07: ucp-1207 kept pr:652,
/// another repo's PR, after agent-land closed it from the wrong session). A row already archived
/// into its version note moves back onto its sheet. The why goes to the log. An id names one row
/// across both lanes (`next_id` never reuses one), so a row the other lane holds reopens there:
/// on 2026-11-12 `reopen ucp-1978` without `--agent` read only the human sheet and found nothing.
pub fn reopen(
    p: &Profile,
    log: &Logger,
    name: &str,
    id: &str,
    why: &str,
    lane: Lane,
) -> Result<i32> {
    if !md::is_row_id(id) {
        bail!("reopen takes a row id such as ar-142, not '{id}'");
    }
    let why = why.trim();
    if why.is_empty() {
        bail!("reopen needs --why: what made the close false");
    }
    let closed =
        |l: &str| l.starts_with("- [") && md::is_checked(l) && md::row_id(l).as_deref() == Some(id);
    let other = match lane {
        Lane::Human => Lane::Agent,
        Lane::Agent => Lane::Human,
    };
    let mut sheets = 0;
    for lane in [lane, other] {
        let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
            continue;
        };
        sheets += 1;
        let done = |verb: &str, row: &str, from: &Path| {
            log.info(
                "ptask",
                &format!("{verb} {id} in {} ({name}): {why}", from.display()),
            );
            let ev = crate::ingest::Event::row("reopened", name, "", lane.name(), row);
            crate::ingest::record(p, &ev);
            println!("reopened {}", row.trim());
        };
        if let Some((new, _)) =
            md::edit_first_in_section(&content, sheet::TASKS, closed, |l| Some(unclose(l)))
        {
            write_sheet(&sheet, &new)?;
            let row = new
                .lines()
                .find(|l| md::row_id(l).as_deref() == Some(id))
                .unwrap_or_default();
            done("reopened", row, &sheet);
            return Ok(0);
        }
        // A row rolled off its sheet is in an agent note, under its lane's section.
        {
            let dir = projects::project_dir(p, name)?;
            for (_, note) in projects::version_notes(&projects::agent_dir(&dir).join("versions")) {
                let text = fs::read_to_string(&note)?;
                let Some((kept, row, detail)) =
                    md::cut_first_block_in_section(&text, archive_section(lane), closed)
                else {
                    continue;
                };
                let mut block = vec![unclose(&row)];
                block.extend(detail);
                // The board first: a failure between the two writes leaves the row in both, never
                // neither. Untidied, since a tidy would archive into the note `kept` was cut from;
                // the sheet is tidied once the note is written.
                let reopened = md::insert_under_heading(&content, sheet::TASKS, &block);
                md::write_atomic(&sheet, &reopened)?;
                md::write_atomic(&note, &kept)?;
                write_sheet(&sheet, &reopened)?;
                done("reopened from the archive", &block[0], &note);
                return Ok(0);
            }
        }
    }
    if sheets == 0 {
        bail!("'{name}' has no task sheet yet");
    }
    eprintln!(
        "no closed task with id {id} in {name}, on its sheet, its agent board or their archives"
    );
    Ok(1)
}

/// `line` open again: `[ ]`, and the marker without what a close stamped. `done` puts its
/// `done:<day>` token first and the proof after it, `drop` its `dropped:` or `dup:`; each only
/// appends, so the close is that token and everything after it. The tokens before it (the id)
/// stay, and so does any text after the marker; a title that quotes one is never read, since only
/// the last marker is. Total: a row is never lost, since `edit_first_in_section` deletes on None.
fn unclose(line: &str) -> String {
    let t = line.trim_end();
    let marker = t
        .rfind("<!--")
        .and_then(|at| Some((at, at + t[at..].find("-->")?)));
    let Some((at, end)) = marker else {
        return md::set_checkbox(t, ' ');
    };
    let inner: Vec<&str> = t[at + 4..end].split_whitespace().collect();
    let cut = inner
        .iter()
        .position(|k| {
            ["done:", "dropped:", "dup:"]
                .iter()
                .any(|c| k.starts_with(c))
        })
        .unwrap_or(inner.len());
    let head = md::set_checkbox(t[..at].trim_end(), ' ');
    let tail = &t[end + 3..];
    match &inner[..cut] {
        [] => format!("{head}{tail}"),
        keep => format!("{head} <!-- {} -->{tail}", keep.join(" ")),
    }
}

/// The marker token `done` stamps beside the proof: the day the row closed, what a project's
/// pace counts (`notes projects --stats --json`). Before the proof, so a prose proof stays last.
pub(crate) fn done_token(day: chrono::NaiveDate) -> String {
    format!("done:{}", day.format("%Y-%m-%d"))
}

/// The day a closed row closed, from its `done:` marker token.
pub(crate) fn done_on(line: &str) -> Option<chrono::NaiveDate> {
    md::marker_token(line, "done:")
        .and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
}

/// `notes ptask <name> tag <query> [--add T]... [--remove T]...` - add or take hashtags off the
/// first matching open task, before its marker. A version tag is refused: `move`, `promote`
/// and `demote` own a row's release.
#[allow(clippy::too_many_arguments)]
pub fn tag(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    add: &[String],
    remove: &[String],
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    let add: Vec<String> = add.iter().map(|t| tag_token(t)).collect::<Result<_>>()?;
    let remove: Vec<String> = remove.iter().map(|t| tag_token(t)).collect::<Result<_>>()?;
    if add.is_empty() && remove.is_empty() {
        bail!("tag needs --add <tag> or --remove <tag>");
    }
    refuse_rewrite(p, name, pick, lane, writer, |l| retag(l, &add, &remove))?;
    let change = add
        .iter()
        .map(|t| format!("+{t}"))
        .chain(remove.iter().map(|t| format!("-{t}")))
        .collect::<Vec<_>>()
        .join(" ");
    Ok(
        edit(p, log, name, pick, "tagged", Some(&change), lane, |l| {
            Some(retag(l, &add, &remove))
        })?
        .0,
    )
}

/// `t` as the `#tag` a row carries, or why it is not one. A release tag is refused: moving a
/// row between versions is `move`, which also clears what is only legal in the open version.
pub(crate) fn tag_token(t: &str) -> Result<String> {
    let t = t.trim().trim_start_matches('#');
    if t.is_empty() || t.contains(char::is_whitespace) {
        bail!("not a tag: '{t}' (want one word, like size/s or requested)");
    }
    if md::is_version_tag(t) {
        bail!("#{t} is a release: use move, promote or demote");
    }
    if let Some(n) = t.strip_prefix("pts/") {
        // Digits only, written back canonical: `+5` and `05` would parse but never match `#pts/5`.
        let pts = Some(n)
            .filter(|n| n.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|n| n.parse::<u32>().ok())
            .filter(|&p| crate::epics::band(p).is_some());
        let Some(pts) = pts else {
            let scale: Vec<String> = crate::epics::POINTS
                .iter()
                .map(|(n, _)| n.to_string())
                .collect();
            bail!("#{t} is off the points scale: one of {}", scale.join(", "));
        };
        return Ok(format!("#pts/{pts}"));
    }
    Ok(format!("#{t}"))
}

/// `line` with `remove` dropped and `add` added. A row has one size and one priority, so
/// adding a `#size/<s>` or a `#urgent`/`#high`/`#normal`/`#low` replaces the one it had. It has one
/// estimate too: adding a `#pts/<n>` replaces its old points and sets its `#size/` to the
/// band they fall in ([`crate::epics::POINTS`]), over any `#size/` added beside them; adding a
/// bare `#size/<s>` drops the points, which no longer hold. So the two never disagree. It has one
/// created stamp too, its origin day, so an added `#cMMDD` lands only on a row with none:
/// `--add c1105` on a `#c1104` row gave nc-71 both (nc-83).
pub(crate) fn retag(line: &str, add: &[String], remove: &[String]) -> String {
    let stamped = md::split_created(line).1.is_some();
    let band = add.iter().find_map(|t| {
        t.strip_prefix("#pts/")
            .and_then(|n| n.parse().ok())
            .and_then(crate::epics::band)
    });
    let banded = band.map(|b| format!("#size/{b}"));
    let add: Vec<&String> = add
        .iter()
        .filter(|t| !(stamped && md::is_created_tag(&t[1..].to_lowercase())))
        .filter(|t| banded.is_none() || !t.starts_with("#size/"))
        .chain(banded.as_ref())
        .collect();
    let sized = add.iter().any(|t| t.starts_with("#size/"));
    let old = size_tag(line).filter(|t| sized && !add.iter().any(|a| *a == t));
    // A new size, banded from new points or set bare, retires every points tag the row had.
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    let old_pts: Vec<String> = head
        .split_whitespace()
        .filter(|w| sized && w.starts_with("#pts/") && !add.iter().any(|a| a == w))
        .map(str::to_string)
        .collect();
    let mut l = old
        .into_iter()
        .map(str::to_string)
        .chain(old_pts)
        .chain(remove.iter().cloned())
        .fold(line.to_string(), |l, t| md::drop_tag(&l, &t));
    if add.iter().any(|a| md::is_priority(a)) {
        l = md::strip_priority_tag(&l);
    }
    add.iter().fold(l, |l, t| md::add_tag(&l, t))
}

/// Is `tag` (`#high`, or bare `high`) one of the priority levels?
/// The row's `#size/<s>` tag, read from its text before the marker comment.
pub(crate) fn size_tag(line: &str) -> Option<&str> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    head.split_whitespace().find(|w| w.starts_with("#size/"))
}

/// The row's `#pts/<n>` tag, read from its text before the marker comment.
pub(crate) fn points_tag(line: &str) -> Option<&str> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    head.split_whitespace().find(|w| w.starts_with("#pts/"))
}

/// The marker text a `done` will stamp, or the error explaining that it needs one.
///
/// The gate itself, kept out of `done` so it is testable without a vault. A bare `done`
/// must FAIL: the roll gate above only means something if a ticked checkbox does.
pub(crate) fn proof_stamp(proof: Option<&str>, unverified: Option<&str>) -> Result<String> {
    match (proof, unverified) {
        (Some(_), Some(_)) => bail!("--proof and --unverified are alternatives; pick one"),
        (Some(r), None) if !r.trim().is_empty() => Ok(r.trim().to_string()),
        (None, Some(w)) if !w.trim().is_empty() => Ok(format!("unverified: {}", w.trim())),
        _ => bail!(
            "done needs proof. one of:\n  \
             --proof pr:1142          a merged PR, a run id, a URL - something checkable\n  \
             --unverified \"<why>\"     no checkable artifact, and this says so out loud"
        ),
    }
}

/// `notes ptask <name> drop --why "<why>" | --dup <id> <query>` - close the first matching open
/// task undelivered. The row stays, ticked, with `dropped: <why>` or `dup:<id>` in its
/// marker, so its id is never reused, its detail lines stay under it, and the sweep and roll
/// treat it as any closed row. There is no delete.
pub fn drop(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    why: Option<&str>,
    dup: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let stamp = drop_stamp(why, dup)?;
    refuse_open_children(p, name, pick, lane, "finish or drop")?;
    Ok(
        edit(p, log, name, pick, "dropped", Some(&stamp), lane, |l| {
            Some(md::add_marker(&closed(l), &stamp))
        })?
        .0,
    )
}

/// Refuse an epic written to the agent board: the human owns epics, and dispatch would start
/// one as a session. `add` and `file` both write rows, so both ask here.
fn refuse_epic_on_board(lane: Lane, texts: &[&str]) -> Result<()> {
    if lane == Lane::Agent && texts.iter().any(|t| crate::epics::is_epic(t)) {
        bail!("an epic belongs on the human sheet: file it on the human lane, not the agent board");
    }
    Ok(())
}

/// Refuse to close an epic on a PR alone: all its leaves landing is the state before verified,
/// and closing there would turn merged back into done. Checked before the edit, so a refusal
/// writes nothing. `--unverified` stays open to it: that stamp says so out loud, and the
/// epic then reads closed but not verified.
fn refuse_landed_as_proof(
    p: &Profile,
    name: &str,
    pick: &Pick,
    lane: Lane,
    stamp: &str,
) -> Result<()> {
    let Some((_, content)) = sheet_and_content(p, name, lane)? else {
        return Ok(());
    };
    match find_open(&content, pick) {
        Some(row) => check_epic_proof(&row, stamp),
        None => Ok(()),
    }
}

/// The gate itself, kept out of [`refuse_landed_as_proof`] so it is testable without a vault.
fn check_epic_proof(row: &str, stamp: &str) -> Result<()> {
    if crate::epics::is_epic(row) && !crate::epics::proves_outcome(stamp) {
        // One line: agent-land reports only a failure's last line.
        bail!(
            "an epic closes on proof of its outcome, and a PR only proves it landed: pass \
             --proof with what was seen live (a URL, a run, a screenshot, the human's word)"
        );
    }
    Ok(())
}

/// Refuse to close the row `pick` names while a child of it (`#of/<its id>`) is open: a
/// parent weighs what its children weigh, so closing it first would report open work as
/// done. Checked before the edit, so a refusal writes nothing.
fn refuse_open_children(
    p: &Profile,
    name: &str,
    pick: &Pick,
    lane: Lane,
    verb: &str,
) -> Result<()> {
    let Some((_, content)) = sheet_and_content(p, name, lane)? else {
        return Ok(());
    };
    let Some(id) = find_open(&content, pick).and_then(|l| md::row_id(&l)) else {
        return Ok(());
    };
    let dir = projects::project_dir(p, name)?;
    let open = crate::epics::Index::of(&dir, projects::open_version(&dir)).open_children(&id);
    if !open.is_empty() {
        // One line: agent-land reports only a failure's last line.
        bail!(
            "{id} has {} open child row(s) ({}); {verb} them first, or re-parent them with \
             `ptask tag <id> --remove of/{id} --add of/<other>`",
            open.len(),
            open.join(", ")
        );
    }
    Ok(())
}

/// The marker a `drop` stamps, or the error saying it needs a reason.
pub(crate) fn drop_stamp(why: Option<&str>, dup: Option<&str>) -> Result<String> {
    match (why.map(str::trim), dup.map(str::trim)) {
        (Some(_), Some(_)) => bail!("--why and --dup are alternatives; pick one"),
        (Some(w), None) if !w.is_empty() => Ok(format!("dropped: {w}")),
        (None, Some(d)) if md::is_row_id(d) => Ok(format!("dup:{d}")),
        (None, Some(d)) => {
            bail!("--dup takes the id of the row this one duplicates (like ar-142), not '{d}'")
        }
        _ => bail!(
            "drop needs a reason. one of:\n  \
             --why \"<why>\"   stale, superseded, moved to its home (\"moved: ideas.md\")\n  \
             --dup <id>      the row it duplicates"
        ),
    }
}

/// A rewrite's `type(area): title #tags` with the title cut to [`projects::TITLE_MAX`] at a word,
/// and the whole title when it was cut, for a `full:` detail line. A title that fits comes back as
/// it is, so the words are never refused and never lost.
fn fit_title(text: &str) -> (String, Option<String>) {
    let bare = text
        .split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .collect::<Vec<_>>()
        .join(" ");
    let Some((ty, area, title)) = projects::row_prefix(&bare) else {
        return (text.to_string(), None);
    };
    if title.chars().count() <= projects::TITLE_MAX {
        return (text.to_string(), None);
    }
    let tags = text.split_whitespace().filter(|w| w.starts_with('#'));
    let head = format!("{ty}({area}): {}", crate::propose::cut(title));
    let fitted: Vec<&str> = std::iter::once(head.as_str()).chain(tags).collect();
    (fitted.join(" "), Some(title.to_string()))
}

/// `notes ptask <name> edit <query> --brief <text>` - replace the first matching open row's
/// brief ([`md::replace_brief`]): its detail lines become `brief`, its child rows stay. The row
/// owns its task's brief, so a correction lands here and a queue item re-snapshots it.
pub fn rebrief(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    brief: &str,
    lane: Lane,
) -> Result<i32> {
    let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet yet");
    };
    let details = [brief.to_string()];
    let Some(new) = md::replace_brief(&content, sheet::TASKS, |l| pick.hits(l), &details) else {
        eprintln!("no open task matches '{pick}' in {name}");
        return Ok(1);
    };
    write_sheet(&sheet, &new)?;
    log.info(
        "ptask",
        &format!("rebriefed in {} ({name})", sheet.display()),
    );
    let row = content.lines().find(|l| pick.hits(l));
    let mut ev = crate::ingest::Event::row(
        "detailed",
        name,
        "",
        lane.name(),
        row.unwrap_or(&pick.to_string()),
    );
    ev.why = Some("brief replaced".into());
    crate::ingest::record(p, &ev);
    println!("rebriefed '{pick}'");
    Ok(0)
}

/// `notes ptask <name> edit <query> --text|--append` - change the first matching task's
/// text in place: replace it, or add `append` to the end of it. Its place on the sheet, its
/// checkbox state and its tags stay as they were ([`md::retext_task`]); the one exception is
/// text-borne tags such as `#plan`, which `--text` drops when it leaves them out, while the
/// sizing (`#size/x`, `#pts/N`) is kept unless `--text` types its own ([`carry_sizing`]).
/// A `#c` stamp or `#of/` link typed in `--text` is dropped when the row has one; a typed `#of/`
/// naming another parent is refused (re-parent with `ptask tag`).
///
/// Each of `details` becomes an indented line at the end of the row's block, after its
/// existing detail lines and child rows. `--detail` alone leaves the row's own line as it is.
///
/// `was` is the triager's rewrite of an open row, the backlog twin of [`file`]: the new text
/// must be `type(area): title`, the old words go first among `details` as `was: <words>`, a title
/// over 80 chars is cut at a word with the whole title on a `full:` line after it ([`fit_title`]), and
/// the old text's own tags (`#requested`, `#tier/3`, `#size/m`) carry over unless the new text
/// sets one of the same name ([`carry_tags`]).
///
/// `systems` (`--link`, the triager's backlog link pass) names the systems command, and the new
/// text then gets the standing-epic default link `add` gives a row ([`link_standing`]); a leaf
/// with no `#of/` that would stay unlinked is refused, exit 1, so a caller never counts it linked.
#[allow(clippy::too_many_arguments)]
pub fn retext(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    text: Option<&str>,
    append: Option<&str>,
    details: &[String],
    was: bool,
    systems: Option<&str>,
    lane: Lane,
    writer: &Writer,
) -> Result<i32> {
    let (text, append) = (text.map(str::trim), append.map(str::trim));
    let rewrite;
    let mut with_was = Vec::new();
    let (text, details) = if was {
        let Some(t) = text.filter(|t| !t.is_empty()) else {
            bail!("--was rewrites a row, so it needs --text \"<type(area): title>\"");
        };
        if !projects::is_typed(t) {
            bail!(
                "'{t}' is not `type(area): title` (README \"The task row\"), so nothing was edited"
            );
        }
        let (t, full) = fit_title(t);
        let t = t.as_str();
        let Some((_, content)) = sheet_and_content(p, name, lane)? else {
            bail!("'{name}' has no task sheet yet");
        };
        let Some((_, line)) =
            md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), |l| Some(l.into()))
        else {
            eprintln!("no open task matches '{pick}' in {name}");
            return Ok(1);
        };
        let old = md::task_text(&line);
        let words = |s: &str| -> Vec<String> {
            s.split_whitespace()
                .filter(|w| !w.starts_with('#'))
                .map(str::to_string)
                .collect()
        };
        if words(&old) == words(t) {
            eprintln!("unchanged: '{t}' has the row's own words, so nothing was edited");
            return Ok(0);
        }
        rewrite = carry_tags(&old, t);
        with_was.push(format!("was: {old}"));
        with_was.extend(full.map(|f| format!("full: {f}")));
        with_was.extend(details.iter().cloned());
        (Some(rewrite.as_str()), &with_was[..])
    } else {
        (text, details)
    };
    let linked;
    let text = match (text, systems) {
        (Some(t), Some(bin)) if !t.is_empty() => {
            // The row is found first: filing a standing epic for an edit that then matches
            // nothing would leave the epic behind with no row under it.
            let found = sheet_and_content(p, name, lane)?.and_then(|(_, content)| {
                md::edit_first_in_section(
                    &content,
                    sheet::TASKS,
                    |l| pick.hits(l),
                    |l| Some(l.into()),
                )
            });
            let Some((_, row)) = found else {
                eprintln!("no open task matches '{pick}' in {name}");
                return Ok(1);
            };
            // Refused here too, before the epic is filed, for the same reason.
            projects::refuse_retired_priority(&row, t)?;
            // A row that has its parent keeps it ([`md::retext_task`]), so a standing epic
            // filed for it would have no child.
            if md::split_parent(&row).1.is_some() {
                Some(t)
            } else {
                let proj_dir = projects::project_dir(p, name)?;
                linked = link_standing(p, log, name, &proj_dir, &[t.to_string()], bin)?;
                match &linked {
                    Some(l) => Some(l[0].as_str()),
                    None if crate::standing::wants_link(t).is_some() => {
                        eprintln!(
                        "--link: '{t}' names no system of {name} (or {name} has no systems list), so nothing was edited"
                    );
                        return Ok(1);
                    }
                    None => Some(t),
                }
            }
        }
        _ => text,
    };
    let has_details = details.iter().any(|d| !d.trim().is_empty());
    if text.or(append).is_none_or(str::is_empty) && !has_details {
        bail!("edit needs the new words: --text \"<new text>\", --append \"<more>\" or --detail \"<line>\"");
    }
    if let Some(t) = text {
        let row = sheet_and_content(p, name, lane)?.and_then(|(_, c)| find_open(&c, pick));
        refuse_reparent(row.as_deref(), name, t)?;
    }
    if let Some(t) = text.filter(|t| crate::epics::is_epic(t)) {
        refuse_epic_on_board(lane, &[t])?;
        let was_epic = sheet_and_content(p, name, lane)?
            .and_then(|(_, c)| find_open(&c, pick))
            .is_some_and(|row| crate::epics::is_epic(&row));
        if !was_epic {
            bail!("edit does not turn a row into an epic: a new epic is an add (`notes ptask {name} add \"epic(<system>): <outcome>\"`), which a session's goes through intake, so nothing was edited");
        }
    }
    if has_details {
        if let Some(rc) = write_details(
            p,
            log,
            name,
            pick,
            lane,
            details,
            text.or(append).is_none_or(str::is_empty),
        )? {
            return Ok(rc);
        }
    }
    let new_row = |l: &str| {
        let new = match (text, append) {
            (Some(t), _) => carry_sizing(&md::task_text(l), t),
            (None, Some(a)) => format!("{} {a}", md::task_text(l)),
            (None, None) => unreachable!("checked above"),
        };
        Some(md::retext_task(l, &new))
    };
    refuse_rewrite(p, name, pick, lane, writer, |l| {
        new_row(l).unwrap_or_default()
    })?;
    Ok(edit(p, log, name, pick, "edited", None, lane, new_row)?.0)
}

/// `edit` keeps a row's `#of/` ([`md::retext_task`]), so a `--text` naming another parent would
/// be dropped in silence: refused, with the command that does re-parent.
fn refuse_reparent(row: Option<&str>, name: &str, text: &str) -> Result<()> {
    let kept = row.and_then(|r| md::split_parent(r).1);
    if let (Some(kept), Some(typed)) = (kept, md::split_parent(text).1) {
        if kept != typed {
            bail!("the row is under #of/{kept}, and edit keeps its parent: #of/{typed} in --text would be dropped. Re-parent with `notes ptask {name} tag <id> --remove of/{kept} --add of/{typed}`, so nothing was edited");
        }
    }
    Ok(())
}

/// `edit --detail`: the lines go at the end of the row's block, and the call is done there
/// (`Some(exit code)`) when no new text comes with them.
fn write_details(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    lane: Lane,
    details: &[String],
    only_details: bool,
) -> Result<Option<i32>> {
    let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet yet");
    };
    let Some(new) = md::append_details(&content, sheet::TASKS, |l| pick.hits(l), details) else {
        eprintln!("no open task matches '{pick}' in {name}");
        return Ok(Some(1));
    };
    write_sheet(&sheet, &new)?;
    log.info(
        "ptask",
        &format!("detailed in {} ({name})", sheet.display()),
    );
    let row = content.lines().find(|l| pick.hits(l));
    let mut ev = crate::ingest::Event::row(
        "detailed",
        name,
        "",
        lane.name(),
        row.unwrap_or(&pick.to_string()),
    );
    ev.why = Some(details.join("; "));
    crate::ingest::record(p, &ev);
    if only_details {
        println!("detailed '{pick}'");
        return Ok(Some(0));
    }
    Ok(None)
}

/// `notes ptask <name> start <query>` - mark the first matching open task in progress (`[/]`).
/// A row already started is left as it is (exit 0, "already started"): start sets, it never
/// toggles, so answering a gate with `start` cannot clear the mark (lesson 2748). `unstart`
/// hands a row back.
///
/// A row going to `[/]` with no id gets one, as [`add`] would have given it: a started row has
/// a queue item, and the item joins its row by that id, which survives a retext. The new id
/// goes on its own `  id:<id>` line after the usual output, so `fleet-dispatch` can read it.
///
/// A row whose item had started (`run:`) and is queued again loses its `run:`: it is back in
/// Next up, not Now.
pub fn start(p: &Profile, log: &Logger, name: &str, pick: &Pick, lane: Lane) -> Result<i32> {
    start_as(p, log, name, pick, lane, false)
}

/// `notes ptask <name> run <query>` - the row's queue item has started: `[/]` plus a
/// `run:MMDD` token in the marker, which puts the row in Now (a `[/]` row without it is
/// queued, in Next up). `agent-queue` writes it on the item's move to running. A row already
/// running is left as it is.
pub fn run(p: &Profile, log: &Logger, name: &str, pick: &Pick, lane: Lane) -> Result<i32> {
    start_as(p, log, name, pick, lane, true)
}

fn start_as(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    lane: Lane,
    running: bool,
) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
    let id = project_map::Registry::load()
        .and_then(|r| r.code(name))
        .map(|code| next_id(&dir, &code));
    let today = chrono::Local::now().format("%m%d").to_string();
    let verb = if running { "running" } else { "started" };
    let (rc, matched) = edit(p, log, name, pick, verb, None, lane, |l| {
        let row = started(l, id.as_deref());
        match (running, is_running(l)) {
            (true, false) => Some(md::add_marker(&row, &format!("run:{today}"))),
            (false, true) => Some(md::remove_marker_token(&row, "run:")),
            _ => (!md::is_in_progress(l)).then_some(row),
        }
    })?;
    if let (Some(line), Some(id)) = (matched, id) {
        let row = started(&line, Some(&id));
        if !md::is_in_progress(&line) && md::row_id(&row).as_deref() == Some(id.as_str()) {
            note_ids(&dir, &[row])?;
            println!("  id:{id}");
        }
    }
    Ok(rc)
}

/// `notes ptask <name> unstart <query>` - hand the first matching started task back to todo
/// (`[/]` -> `[ ]`). A row not started is left as it is (exit 0, "not started").
pub fn unstart(p: &Profile, log: &Logger, name: &str, pick: &Pick, lane: Lane) -> Result<i32> {
    Ok(edit(p, log, name, pick, "unstarted", None, lane, |l| {
        md::is_in_progress(l).then(|| md::remove_marker_token(&md::set_checkbox(l, ' '), "run:"))
    })?
    .0)
}

/// `line` ticked closed. A closed row runs nothing, so its `run:` token goes with the checkbox.
fn closed(line: &str) -> String {
    md::set_checkbox(&md::remove_marker_token(line, "run:"), 'x')
}

/// A started row whose queue item is running: `[/]` with a `run:` token.
pub(crate) fn is_running(line: &str) -> bool {
    md::is_in_progress(line) && md::marker_token(line, "run:").is_some()
}

/// One row through `start`: `[/]`, stamped with `id` when it carries none.
fn started(line: &str, id: Option<&str>) -> String {
    let started = md::set_checkbox(line, '/');
    match id.filter(|_| md::row_id(line).is_none()) {
        Some(id) => md::add_marker(&started, &format!("id:{id}")),
        None => started,
    }
}

/// `notes ptask <name> sweep [--dry-run]` - lay the sheet's `## Tasks` out in its sections
/// and roll its old closed rows into the version note ([`tidy`]).
///
/// Logs under `ptask:` like every other verb here, because the Stop gate greps the notes log
/// for `(focus|ptask):` to decide a turn made progress; a verb logged under anything else is
/// invisible to it and the session gets blocked for work it did.
pub fn sweep(p: &Profile, log: &Logger, name: &str, dry_run: bool, lane: Lane) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(sheet) = task_sheet(&dir) else {
        bail!("{name} has no task sheet with a `## Tasks` section");
    };
    let content = fs::read_to_string(&sheet)?;
    let Some(t) = sweep_file(&sheet, &content, Pass::Sweep, dry_run)? else {
        println!("{name}: already swept");
        return Ok(0);
    };
    for r in &t.report {
        println!("{r}");
    }
    if dry_run {
        println!("--dry-run: {} would change", sheet.display());
        return Ok(0);
    }
    md::write_atomic(&sheet, &t.content)?;
    log.info("ptask", &format!("swept {name}'s tasks"));
    let mut ev = crate::ingest::Event::new("swept", name, "", &t.report.join("; "));
    ev.stage = Some("backlog".into());
    ev.lane = lane.name().into();
    crate::ingest::record(p, &ev);
    println!("{}", sheet.display());
    Ok(0)
}

/// `notes sheet-sweep <PATH>` - sweep one sheet file by path, the editor's entry point.
///
/// With `--stdin` the buffer comes on stdin and the swept buffer goes to stdout, unchanged
/// when there is nothing to do, and the file itself is left to the editor's save. That is
/// editor mode: a row ticked by hand without a `done:` date gets today's. Without `--stdin`
/// the file is swept in place. `--layout-only` (with `--stdin`) only re-sorts the sections,
/// stamping, retagging and rolling off nothing: the editor's live re-sort, which runs before
/// any save. A path that is no project sheet ([`is_sheet_path`]) is left as it is.
pub fn sheet_sweep(path: &Path, stdin: bool, layout_only: bool, dry_run: bool) -> Result<i32> {
    use std::io::Read;
    let content = if stdin {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        buf
    } else {
        fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?
    };
    if is_playtest_path(path) {
        return crate::playtest::sheet_sweep(path, &content, stdin, layout_only, dry_run);
    }
    if !is_sheet_path(path) || !crate::config::managed_path(path) {
        if stdin {
            print!("{content}");
        }
        return Ok(0);
    }
    if layout_only {
        let (lane, dir) = sheet_home(path);
        let ctx = sweep_ctx(&dir, lane, &content, false);
        let swept = project_sweep::sweep_sheet(&content, &ctx).map(|(c, _)| c);
        print!("{}", swept.as_deref().unwrap_or(&content));
        return Ok(0);
    }
    let pass = if stdin { Pass::Editor } else { Pass::Sweep };
    let t = sweep_file(path, &content, pass, dry_run)?;
    if stdin {
        print!(
            "{}",
            t.as_ref().map_or(content.as_str(), |t| t.content.as_str())
        );
        return Ok(0);
    }
    let Some(t) = t else {
        return Ok(0);
    };
    for r in &t.report {
        println!("{r}");
    }
    if !dry_run {
        md::write_atomic(path, &t.content)?;
    }
    Ok(0)
}

/// `notes projects --sweep` - sweep every project sheet and agent board in every profile:
/// what ages the Done window and the due buckets on a night nothing else wrote a sheet.
pub fn sweep_all(log: &Logger, dry_run: bool) -> Result<i32> {
    let (mut changed, mut archived, mut failed) = (0, 0, 0);
    for profile in crate::config::managed_profile_names()? {
        let Ok(p) = crate::config::resolve(Some(&profile)) else {
            continue;
        };
        for (_, summary) in crate::daily::discover_project_dirs(&p) {
            let Some(dir) = summary.parent() else {
                continue;
            };
            match sweep_playtest(dir, dry_run) {
                Ok(None) => {}
                Ok(Some((file, report, n))) => {
                    println!("{}", file.display());
                    for r in &report {
                        println!("  {r}");
                    }
                    changed += 1;
                    archived += n;
                }
                Err(e) => {
                    eprintln!("{}: {e:#}", crate::playtest::path(dir).display());
                    failed += 1;
                }
            }
            let sheets = [task_sheet(dir), task_sheet(&dir.join("agent"))];
            for sheet in sheets.into_iter().flatten() {
                match sweep_one(&sheet, dry_run) {
                    Ok(None) => {}
                    Ok(Some(t)) => {
                        println!("{}", sheet.display());
                        for r in &t.report {
                            println!("  {r}");
                        }
                        changed += 1;
                        archived += t.archived;
                    }
                    // One bad sheet is that project's to fix; every other sheet still sweeps.
                    Err(e) => {
                        eprintln!("{}: {e:#}", sheet.display());
                        failed += 1;
                    }
                }
            }
        }
    }
    let verb = if dry_run { "would change" } else { "swept" };
    println!("{verb} {changed} sheet(s), {archived} closed row(s) rolled off");
    if !dry_run && changed > 0 {
        log.info(
            "projects",
            &format!("swept {changed} sheet(s), archived {archived}"),
        );
    }
    if failed > 0 {
        eprintln!("{failed} sheet(s) failed");
        return Ok(1);
    }
    Ok(0)
}

/// Sweep `dir`'s playtest.md in place (unless `dry_run`): the file, its report and how many
/// ticked checks rolled off; `None` when it has none or nothing changed.
fn sweep_playtest(dir: &Path, dry_run: bool) -> Result<Option<(PathBuf, Vec<String>, usize)>> {
    let file = crate::playtest::path(dir);
    let Ok(content) = fs::read_to_string(&file) else {
        return Ok(None);
    };
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let Some(laid) = crate::playtest::tidy(dir, &name, &content, dry_run)? else {
        return Ok(None);
    };
    if !dry_run {
        md::write_atomic(&file, &laid.content)?;
    }
    let n = laid.old.iter().map(|(_, r)| r.len()).sum();
    Ok(Some((file, crate::playtest::report(dir, &laid), n)))
}

/// Sweep the sheet at `sheet` in place (unless `dry_run`): what it did, `None` for nothing.
fn sweep_one(sheet: &Path, dry_run: bool) -> Result<Option<Tidied>> {
    let content = fs::read_to_string(sheet).with_context(|| format!("read {}", sheet.display()))?;
    let t = sweep_file(sheet, &content, Pass::Sweep, dry_run)?;
    if let Some(t) = t.as_ref().filter(|_| !dry_run) {
        md::write_atomic(sheet, &t.content)?;
    }
    Ok(t)
}

/// A path a project sheet or agent board lives at: `README.md` or `tasks.md`, never inside a
/// `versions/` or `docs/` folder. A frozen version or a docs page can carry `## Tasks` too,
/// and sweeping one would strip a record that is meant to stay as written.
fn is_sheet_path(path: &Path) -> bool {
    let named = path
        .file_name()
        .is_some_and(|n| n == "README.md" || n == "tasks.md");
    named && outside_frozen_dirs(path)
}

/// No `versions/` or `docs/` above `path`: a note there is history or prose, never swept.
fn outside_frozen_dirs(path: &Path) -> bool {
    !path
        .parent()
        .into_iter()
        .flat_map(Path::components)
        .any(|c| c.as_os_str() == "versions" || c.as_os_str() == "docs")
}

/// A project's `playtest.md`.
fn is_playtest_path(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n == "playtest.md") && outside_frozen_dirs(path)
}

/// What one [`tidy`] did to a sheet.
pub(crate) struct Tidied {
    pub content: String,
    pub report: Vec<String>,
    pub archived: usize,
}

/// The lane and project dir a sheet path belongs to: `<dir>/agent/README.md` is the agent
/// board, anything else the project's own sheet.
fn sheet_home(sheet: &Path) -> (Lane, PathBuf) {
    let parent = sheet.parent().unwrap_or(Path::new("."));
    match (parent.file_name(), parent.parent()) {
        (Some(n), Some(dir)) if n == "agent" => (Lane::Agent, dir.to_path_buf()),
        _ => (Lane::Human, parent.to_path_buf()),
    }
}

/// The section of `agent/versions/<v>.md` a lane's rolled-off closed rows go under. Two, so a
/// reader can tell the human's rows from the agents' (`board --version`, `reopen`).
pub(crate) fn archive_section(lane: Lane) -> &'static str {
    match lane {
        Lane::Agent => "Done rows",
        Lane::Human => SHEET_DONE_ROWS,
    }
}

/// The closed rows a version note holds under both lanes' [`archive_section`]s.
pub(crate) fn note_done_rows(note: &str) -> Vec<String> {
    let lines: Vec<&str> = note.lines().collect();
    let mut out = Vec::new();
    for lane in [Lane::Agent, Lane::Human] {
        let Some(span) = md::section_span(&lines, archive_section(lane)) else {
            continue;
        };
        let body = lines[span].join("\n");
        let rows: Vec<&str> = body.lines().collect();
        out.extend(
            done_rows(&body)
                .into_iter()
                .map(|r| rows[r.start].to_string()),
        );
    }
    out
}

/// [`archive_section`] of the human sheet.
pub(crate) const SHEET_DONE_ROWS: &str = "Sheet done rows";

/// Lay out the sheet at `sheet` whose text is `content`: date the boxes ticked by hand when
/// `editor` (the save hook's buffer), roll the old closed rows into the version note, and
/// sweep the rest into sections. `None` when nothing would change. Writes the note only, and
/// only when not `dry_run`; the caller writes the sheet, so a failure between the two leaves
/// rows in both, never neither. On a human sheet it also closes the playtest checks of every
/// play-build row closed done ([`crate::playtest::close_played`], which writes playtest.md);
/// a failure there is reported and retried by the next sweep, never a reason to refuse the
/// sheet's own write.
pub(crate) fn sweep_file(
    sheet: &Path,
    content: &str,
    pass: Pass,
    dry_run: bool,
) -> Result<Option<Tidied>> {
    if !crate::config::managed_path(sheet) {
        return Ok(None);
    }
    let (lane, dir) = sheet_home(sheet);
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let ctx = sweep_ctx(&dir, lane, content, pass != Pass::Write);
    // The editor dates a box ticked in this edit, so a row already closed and undated in the
    // saved file (an old close from before `done:`) is no new tick.
    let saved = (pass == Pass::Editor).then(|| fs::read_to_string(sheet).unwrap_or_default());
    let mut t = tidy(&dir, &name, lane, content, &ctx, saved.as_deref(), dry_run)?;
    // A play-build row ticked done in this content closes the playtest checks it covered.
    let played = match lane {
        Lane::Human => {
            crate::playtest::close_played(&dir, &name, content, dry_run).unwrap_or_else(|e| {
                eprintln!(
                    "{}: played checks not closed: {e:#}",
                    crate::playtest::path(&dir).display()
                );
                Vec::new()
            })
        }
        Lane::Agent => Vec::new(),
    };
    let closed = !played.is_empty();
    t.report.extend(played);
    Ok((closed || t.content != content).then_some(t))
}

/// What a sweep of `content`, a sheet under `dir`, is measured against: today, the `[sheet]`
/// shape (on the agent lane, its tier) and the open version, read from `content` itself so an editor buffer's unsaved
/// `Version:` bump counts (an agent board's comes from the human sheet).
pub(crate) fn sweep_ctx(
    dir: &Path,
    lane: Lane,
    content: &str,
    rewrite: bool,
) -> project_sweep::Ctx {
    let shape = crate::config::sheet_shape();
    // An agent board carries no `Version:` line; its version is the human sheet's, the one the
    // window is read against, so the rows it rolls off land in the note the sprint count reads.
    let open = match lane {
        Lane::Agent => open_version_for(dir),
        Lane::Human => version_in(dir, content),
    };
    project_sweep::Ctx {
        today: chrono::Local::now().date_naive(),
        shape,
        tiered: lane == Lane::Agent,
        aim: crate::rank::Aim::of_swept(dir, lane == Lane::Agent, content),
        open,
        rewrite,
        systems: epic_systems(dir, content, crate::standing::SYSTEMS_BIN),
    }
}

/// The days of shipped work a budget is measured over.
pub(crate) const BUDGET_WINDOW_DAYS: u32 = 7;

/// A project's work capacity in weight: `days` of the weight its agent rows shipped with a PR
/// over the last [`BUDGET_WINDOW_DAYS`] days, rounded up, which sizes a release window's commit
/// (`window::record`); `agent_board_floor` covers a project that shipped nothing.
pub(crate) fn board_budget(dir: &Path, days: u32) -> u32 {
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let today = chrono::Local::now().date_naive();
    let shipped = crate::board::shipped_weight(&name, dir, today, BUDGET_WINDOW_DAYS.into());
    (shipped * days).div_ceil(BUDGET_WINDOW_DAYS)
}

/// The systems `### Epics` is ordered by, read only when there is an order to keep: two or more
/// open epic rows. The dir's name is the project the list is keyed by; a project with no list
/// orders its epics by area word alone.
fn epic_systems(dir: &Path, content: &str, bin: &str) -> Vec<crate::standing::System> {
    let epics = content
        .lines()
        .filter(|l| md::is_open_task(l) && crate::epics::is_epic(l))
        .count();
    if epics < 2 {
        return vec![];
    }
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    crate::standing::list(bin, &name).unwrap_or_default()
}

/// Which sweep a sheet gets. `Write` ends every `ptask` write: rows move, none is rewritten.
/// `Sweep` is the explicit and nightly pass, which also retags. `Editor` is a save in the
/// editor, which also dates a box ticked by hand.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Pass {
    Write,
    Sweep,
    Editor,
}

/// [`sweep_file`] with its context given, for tests.
pub(crate) fn tidy(
    dir: &Path,
    name: &str,
    lane: Lane,
    content: &str,
    ctx: &project_sweep::Ctx,
    saved: Option<&str>,
    dry_run: bool,
) -> Result<Tidied> {
    let stamped = match saved {
        Some(saved) => project_sweep::stamp_undated(content, saved, ctx.today),
        None => content.to_string(),
    };
    let old = project_sweep::old_done(&stamped, ctx);
    let mut report = Vec::new();
    let (rest, archived) = if old.is_empty() {
        (stamped, 0)
    } else {
        let ver = projects::version_or_default(ctx.open);
        report.push(format!(
            "{} closed row(s) -> {} ## {}",
            old.len(),
            projects::agent_note_path(dir, &ver).display(),
            archive_section(lane)
        ));
        let kept = if dry_run {
            cut_rows(&stamped, &old)
        } else {
            archive_rows(dir, name, ctx.open, &stamped, &old, archive_section(lane))?
        };
        (kept, old.len())
    };
    let (content, more) = project_sweep::sweep_sheet(&rest, ctx).unwrap_or((rest, Vec::new()));
    report.extend(more);
    Ok(Tidied {
        content,
        report,
        archived,
    })
}

/// Write a sheet the way every `ptask` verb does: swept into its sections first ([`tidy`]), so
/// no write can leave a sheet out of shape and no reader has to sort it again.
pub(crate) fn write_sheet(sheet: &Path, content: &str) -> Result<()> {
    let swept = sweep_file(sheet, content, Pass::Write, false)?.map(|t| t.content);
    md::write_atomic(sheet, swept.as_deref().unwrap_or(content))
}

/// The done rows on a sheet, as line ranges: each top-level checked task with the indented
/// lines under it. A checked subtask under an open row is part of that row and stays.
pub(crate) fn done_rows(content: &str) -> Vec<std::ops::Range<usize>> {
    let lines: Vec<&str> = content.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i];
        if !(l.starts_with("- [") && md::is_checked(l)) {
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < lines.len()
            && !lines[end].trim().is_empty()
            && lines[end].starts_with([' ', '\t'])
        {
            end += 1;
        }
        out.push(i..end);
        i = end;
    }
    out
}

/// The done rows that belong to the open version `cur`: a closed row aimed at a later release
/// waits for that release, as it does on the human sheet.
pub(crate) fn done_rows_of(content: &str, cur: Option<V>) -> Vec<std::ops::Range<usize>> {
    let lines: Vec<&str> = content.lines().collect();
    done_rows(content)
        .into_iter()
        .filter(|r| !sheet::is_later(lines[r.start], cur))
        .collect()
}

/// Put `rows` at the end of the agent note's `## <section>`, adding the section at the foot
/// of the note when it has none.
fn append_done_rows(content: &str, section: &str, rows: &[String]) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    match md::section_span(&lines, section) {
        Some(span) => {
            // after the section's last non-blank line, so the rows stay one list
            let at = lines[span.clone()]
                .iter()
                .rposition(|l| !l.trim().is_empty())
                .map_or(span.start, |k| span.start + k + 1);
            for (k, r) in rows.iter().enumerate() {
                out.insert(at + k, r.clone());
            }
        }
        None => {
            while out.last().is_some_and(|l| l.trim().is_empty()) {
                out.pop();
            }
            out.push(String::new());
            out.push(format!("## {section}"));
            out.extend(rows.iter().cloned());
        }
    }
    format!("{}\n", out.join("\n"))
}

/// `notes ptask <name> --agent archive [--dry-run]` - move the agent board's done rows into
/// `agent/versions/<vX.Y.Z>.md` (the human sheet's open version), under `## Done rows`, verbatim
/// and in board order, each with the proof stamp `done` put on it.
///
/// Every sheet write already rolls done rows off past the `[sheet]` window (see [`tidy`]);
/// this verb is the explicit, whole-board form for the agent lane.
pub fn archive(p: &Profile, log: &Logger, name: &str, dry_run: bool, lane: Lane) -> Result<i32> {
    if lane == Lane::Human {
        bail!(
            "archive moves the agent board's done rows (--agent); the human sheet's done rows freeze with `notes projects --release`"
        );
    }
    let dir = projects::project_dir(p, name)?;
    let board = crate::agent_sheet::sheet_path(&dir);
    let Ok(content) = fs::read_to_string(&board) else {
        bail!("{name} has no agent board ({})", board.display());
    };
    let cur = open_version_for(&dir);
    let ranges = done_rows_of(&content, cur);
    if ranges.is_empty() {
        println!("{name}: no done rows on the agent board");
        return Ok(0);
    }
    let ver = projects::version_or_default(cur);
    let note = projects::agent_note_path(&dir, &ver);
    if dry_run {
        println!(
            "--dry-run: {} done rows would move from {} to {}",
            ranges.len(),
            board.display(),
            note.display()
        );
        return Ok(0);
    }

    // The note first: a failure between the two writes leaves rows in both, never neither.
    let (kept, n) = archive_done_rows(&dir, name, cur, &content)?;
    write_sheet(&board, &kept)?;
    log.info(
        "ptask",
        &format!("archived {n} done rows ({name}) -> {}", note.display()),
    );
    let mut ev = crate::ingest::Event::new("archived", name, "", &format!("{n} done rows"));
    ev.stage = Some("backlog".into());
    ev.lane = lane.name().into();
    crate::ingest::record(p, &ev);
    println!("moved {n} done rows -> {}", note.display());
    Ok(0)
}

/// `notes ptask <name> --agent archive [--rehome] [--dry-run]`: [`archive`], or with `rehome`
/// [`rehome`] (`misfiled`).
pub fn archive_verb(
    p: &Profile,
    log: &Logger,
    name: &str,
    dry_run: bool,
    misfiled: bool,
    lane: Lane,
) -> Result<i32> {
    if misfiled {
        rehome(p, log, name, dry_run, lane)
    } else {
        archive(p, log, name, dry_run, lane)
    }
}

/// `notes ptask <name> --agent archive --rehome [--dry-run]` - move the agent done rows closed since the
/// open window opened out of `versions/v0.0.1.md`, where a roll-off filed them before
/// [`sweep_ctx`] read the human sheet's version, into the open version's note, which is where
/// the sprint count reads them.
pub fn rehome(p: &Profile, log: &Logger, name: &str, dry_run: bool, lane: Lane) -> Result<i32> {
    if lane == Lane::Human {
        bail!("rehome moves the agent board's archived done rows (--agent)");
    }
    let dir = projects::project_dir(p, name)?;
    let n = rehome_rows(&dir, name, dry_run)?;
    if n > 0 && !dry_run {
        log.info("ptask", &format!("re-homed {n} done rows ({name})"));
        let mut ev = crate::ingest::Event::new("archived", name, "", &format!("{n} done rows"));
        ev.stage = Some("backlog".into());
        ev.lane = lane.name().into();
        crate::ingest::record(p, &ev);
    }
    println!(
        "{name}: {n} done rows {} the open version's note",
        if dry_run { "would move to" } else { "moved to" }
    );
    Ok(0)
}

/// Move the done rows of `versions/v0.0.1.md` dated on or after the open window's `opened` into
/// the open version's note; how many. Nothing moves for a project whose open version is
/// `v0.0.1` (the note is right there), with no recorded window, or for a row with no `done:` day.
fn rehome_rows(dir: &Path, name: &str, dry_run: bool) -> Result<usize> {
    let Some(cur) = open_version_for(dir).filter(|c| *c != (0, 0, 1)) else {
        return Ok(0);
    };
    let Some(opened) = crate::window::read(&crate::window::home(dir), cur).map(|s| s.opened) else {
        return Ok(0);
    };
    let from = projects::agent_note_path(dir, &projects::version_or_default(None));
    let Ok(note) = fs::read_to_string(&from) else {
        return Ok(0);
    };
    let lines: Vec<&str> = note.lines().collect();
    let Some(span) = md::section_span(&lines, archive_section(Lane::Agent)) else {
        return Ok(0);
    };
    let body = lines[span.clone()].join("\n");
    let moved: Vec<std::ops::Range<usize>> = done_rows(&body)
        .into_iter()
        .filter(|r| done_on(lines[span.start + r.start]).is_some_and(|d| d >= opened))
        .collect();
    if moved.is_empty() || dry_run {
        return Ok(moved.len());
    }
    let blocks: Vec<Vec<String>> = moved
        .iter()
        .map(|r| {
            lines[span.start + r.start..span.start + r.end]
                .iter()
                .map(|l| (*l).to_string())
                .collect()
        })
        .collect();
    // The target first: a failure between the two writes leaves rows in both, never neither.
    archive_blocks(dir, name, Some(cur), archive_section(Lane::Agent), &blocks)?;
    let at: Vec<std::ops::Range<usize>> = moved
        .iter()
        .map(|r| span.start + r.start..span.start + r.end)
        .collect();
    md::write_atomic(&from, &cut_rows(&note, &at))?;
    Ok(moved.len())
}

/// Append a board's done rows to `agent/versions/<ver>.md` under `## Done rows` and return
/// the board without them, plus how many moved. Writes the note only; the caller writes the
/// board after, so a failure between the two leaves rows in both, never neither.
///
/// Shared by `ptask --agent archive` and `notes projects --release`, which closes a version's
/// agent board with it.
pub(crate) fn archive_done_rows(
    dir: &Path,
    name: &str,
    cur: Option<V>,
    content: &str,
) -> Result<(String, usize)> {
    let ranges = done_rows_of(content, cur);
    if ranges.is_empty() {
        return Ok((content.to_string(), 0));
    }
    let kept = archive_rows(
        dir,
        name,
        cur,
        content,
        &ranges,
        archive_section(Lane::Agent),
    )?;
    Ok((kept, ranges.len()))
}

/// Append the rows at `ranges` of `content` to the open version's agent note under
/// `## <section>`, and return `content` without them. Writes the note only.
fn archive_rows(
    dir: &Path,
    name: &str,
    cur: Option<V>,
    content: &str,
    ranges: &[std::ops::Range<usize>],
    section: &str,
) -> Result<String> {
    let lines: Vec<&str> = content.lines().collect();
    let blocks: Vec<Vec<String>> = ranges
        .iter()
        .map(|r| lines[r.clone()].iter().map(|l| (*l).to_string()).collect())
        .collect();
    archive_blocks(dir, name, cur, section, &blocks)?;
    Ok(cut_rows(content, ranges))
}

/// Append closed row `blocks` (each a row and the lines indented under it) to `## <section>` of
/// the version note for `cur`, creating the note as needed. The one writer of rolled-off rows,
/// for the sheets and `playtest.md` alike.
pub(crate) fn archive_blocks(
    dir: &Path,
    name: &str,
    cur: Option<V>,
    section: &str,
    blocks: &[Vec<String>],
) -> Result<()> {
    if blocks.is_empty() {
        return Ok(());
    }
    let ver = projects::version_or_default(cur);
    let note = projects::ensure_agent_note(dir, name, &ver)?;
    let prior = fs::read_to_string(&note)?;
    // A row already in the note is not written twice: an editor buffer undone past its save,
    // or a sheet written back from a stale copy, offers the same row again. Known by its id
    // only: two id-less rows can share every byte and still be two closes, and both are cut.
    let prior_lines: Vec<&str> = prior.lines().collect();
    let have: std::collections::HashSet<String> = md::section_span(&prior_lines, section)
        .map(|span| {
            prior_lines[span]
                .iter()
                .filter_map(|l| md::row_id(l))
                .collect()
        })
        .unwrap_or_default();
    let rows: Vec<String> = blocks
        .iter()
        .filter(|b| md::row_id(&b[0]).is_none_or(|id| !have.contains(&id)))
        .flat_map(|b| {
            // A closed row is in no tier, here as on the sheet: `reopen` brings it back clean.
            let first = project_sweep::with_backlog(&b[0], false);
            std::iter::once(first).chain(b[1..].iter().cloned())
        })
        .collect();
    if !rows.is_empty() {
        md::write_atomic(&note, &append_done_rows(&prior, section, &rows))?;
    }
    Ok(())
}

/// `content` without the lines at `ranges`.
fn cut_rows(content: &str, ranges: &[std::ops::Range<usize>]) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let mut drop = vec![false; lines.len()];
    for i in ranges.iter().flat_map(|r| r.clone()) {
        drop[i] = true;
    }
    let kept: Vec<&str> = lines
        .iter()
        .zip(&drop)
        .filter(|(_, d)| !**d)
        .map(|(l, _)| *l)
        .collect();
    format!("{}\n", kept.join("\n"))
}

/// Shared body for `done`/`drop`/`start`/`unstart`/`tag`: apply `f` to the first open task
/// matching `query`; `f` returning None leaves the row as it is (no write, no record, exit 0,
/// "unchanged"). Returns `(exit_code, matched_line)`. Non-zero exit on no-match (the cockpit
/// drives these through `execute-silent`, which discards stdout, so a zero exit would hide
/// "matched nothing").
#[allow(clippy::too_many_arguments)]
fn edit<F>(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    verb: &str,
    why: Option<&str>,
    lane: Lane,
    f: F,
) -> Result<(i32, Option<String>)>
where
    F: Fn(&str) -> Option<String>,
{
    let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    let after = std::cell::RefCell::new(None);
    let write = |l: &str| {
        // A row is written with one priority tag, whatever the edit added (nc-70).
        let new = f(l).map(|n| md::one_priority(&n));
        after.borrow_mut().clone_from(&new);
        Some(new.unwrap_or_else(|| l.to_string()))
    };
    match md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), write) {
        Some((_, matched)) if after.borrow().is_none() => {
            println!("unchanged {}", matched.trim());
            Ok((0, Some(matched)))
        }
        Some((new, matched)) => {
            // No edit writes a priority word no reader knows (`tag --add p1`, `edit --text "... #p1"`).
            if let Some(line) = after.borrow().as_deref() {
                projects::refuse_retired_priority(&matched, line)?;
            }
            write_sheet(&sheet, &new)?;
            log.info("ptask", &format!("{verb} in {} ({name})", sheet.display()));
            let mut ev = crate::ingest::Event::row(verb, name, "", lane.name(), &matched);
            if verb == "done" {
                ev = ev.proof(why.unwrap_or_default());
            }
            ev.why = why.map(str::to_string);
            if verb == "edited" {
                ev.row = after.into_inner().map(|l| md::task_text(&l));
            }
            crate::ingest::record(p, &ev);
            println!("{verb} {}", matched.trim());
            Ok((0, Some(matched)))
        }
        None => {
            eprintln!("no open task matches '{pick}' in {name}");
            Ok((1, None))
        }
    }
}

/// Refuse `writer` an edit of the first open row `pick` matches when `rewrite` would change the
/// row's priority or its `#vX.Y.Z` aim and the open sprint holds the row
/// ([`crate::window::refuse_held`]): a reprioritize or a move, made by `tag` or new words.
fn refuse_rewrite(
    p: &Profile,
    name: &str,
    pick: &Pick,
    lane: Lane,
    writer: &Writer,
    rewrite: impl Fn(&str) -> String,
) -> Result<()> {
    let Some((_, content)) = sheet_and_content(p, name, lane)? else {
        return Ok(());
    };
    let keep = |l: &str| Some(l.to_string());
    let Some((_, line)) = md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), keep)
    else {
        return Ok(());
    };
    let after = md::one_priority(&rewrite(&line));
    if md::task_priority(&after) == md::task_priority(&line)
        && sheet::target(&after) == sheet::target(&line)
    {
        return Ok(());
    }
    let proj = projects::project_dir(p, name)?;
    let cur = version_in(&lane.dir(&proj), &content);
    let what = "changing the priority or version of";
    crate::window::refuse_held(&proj, cur, &line, writer, what)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A words pick, as `ptask <verb> <query>` builds one.
    fn w(q: &str) -> Pick {
        Pick::new(q, false).unwrap()
    }

    #[test]
    fn an_exact_pick_hits_only_its_own_line_byte_for_byte() {
        let raw = "- [ ] Second task #high";
        let pick = Pick::new(raw, true).unwrap();
        assert!(pick.hits("- [ ] Second task #high"));
        assert!(
            pick.hits("- [ ] Second task #high  "),
            "trailing space is not an edit"
        );
        // Every edit someone else could have made since the UI read the row.
        assert!(!pick.hits("- [ ] second task #high"), "retexted");
        assert!(!pick.hits("- [/] Second task #high"), "started");
        assert!(!pick.hits("- [x] Second task #high"), "ticked");
        assert!(!pick.hits("- [ ] Second task #low"), "reprioritised");
        assert!(
            !pick.hits("- [ ] Second task #high and more"),
            "a longer row"
        );
        // The sweep moving a row in or out of the Backlog tier is not an edit.
        assert!(pick.hits("- [ ] Second task #high <!-- tier:backlog -->"));
        let tiered =
            Pick::new("- [ ] Second task #high <!-- id:x-1 tier:backlog -->", true).unwrap();
        assert!(tiered.hits("- [ ] Second task #high <!-- id:x-1 -->"));
        assert!(
            !tiered.hits("- [ ] Second task #high <!-- id:x-2 -->"),
            "another marker"
        );
        // Words still match by contained, case-folded text.
        assert!(w("SECOND").hits("- [ ] Second task #high"));
    }

    #[test]
    fn a_pick_refuses_what_could_match_the_wrong_row() {
        assert!(
            Pick::new("  ", false).is_err(),
            "empty words match every row"
        );
        assert!(
            Pick::new("second task", true).is_err(),
            "exact needs the whole line"
        );
        assert!(
            Pick::new("- [x] done task", true).is_err(),
            "a closed row is never a target"
        );
        assert!(
            Pick::new("- [ ] ", true).is_err(),
            "the placeholder is not a row"
        );
    }

    #[test]
    fn an_exact_pick_refuses_twin_rows() {
        let dir = std::env::temp_dir().join(format!("ptask-twins-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let sheet = dir.join("README.md");
        let row = "- [ ] Same row #high";
        fs::write(&sheet, format!("## Tasks\n{row}\n- [ ] other\n")).unwrap();
        let pick = Pick::new(row, true).unwrap();
        assert!(pick.sole_in(&sheet).is_ok(), "one copy is fine");
        // NEGATIVE CONTROL: a second identical line anywhere on the sheet is refused.
        fs::write(
            &sheet,
            format!("## Tasks\n{row}\n\n---\n### Done\n\n## Backlog\n{row}\n"),
        )
        .unwrap();
        assert!(pick.sole_in(&sheet).is_err());
        // Words picks keep their first-match behaviour.
        assert!(w("same").sole_in(&sheet).is_ok());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_stale_exact_pick_moves_nothing() {
        let stale = Pick::new("- [ ] spawn bug that was renamed since", true).unwrap();
        assert!(retarget(SRC, &stale, (0, 5, 0), SRC_CUR).is_none());
        assert!(lift(&stale, None).unwrap().is_none());
    }

    const SHEET: &str = "\
# demo
Version: v0.1.0

## Tasks
- [ ] first task
- [x] done task
- [/] doing this
- [ ] second task

## Backlog
- [ ] later
";

    #[test]
    fn a_prose_readme_grows_the_sections_at_its_end() {
        let dir = std::env::temp_dir().join(format!("ptask-prose-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("README.md"),
            "# demo\nVersion: v0.2.0\n\nsome prose\n",
        )
        .unwrap();

        let body = fs::read_to_string(ensure_task_sheet(&dir, "demo").unwrap()).unwrap();
        assert!(
            body.starts_with("# demo\nVersion: v0.2.0\n\nsome prose\n"),
            "{body}"
        );
        assert!(body.ends_with(&sheet::skeleton()), "{body}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_fresh_sheet_carries_the_sections_and_no_version() {
        let dir = std::env::temp_dir().join(format!("ptask-fresh-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let body = fs::read_to_string(ensure_task_sheet(&dir, "demo").unwrap()).unwrap();
        assert_eq!(body, format!("# demo\n\n{}", sheet::skeleton()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn list_positions_cover_only_open_tasks() {
        let open: Vec<_> = sheet::open_rows(SHEET)
            .into_iter()
            .map(|(_, l)| md::task_key(l))
            .collect();
        // the two todos + the in-progress task; NOT the checked one, NOT the backlog item
        assert_eq!(open, vec!["first task", "doing this", "second task"]);
    }

    #[test]
    fn edit_first_ticks_only_the_matching_task() {
        let (out, matched) = md::edit_first_in_section(
            SHEET,
            sheet::TASKS,
            |l| is_match(l, "second"),
            |l| Some(md::set_checkbox(l, 'x')),
        )
        .unwrap();
        assert!(matched.contains("second task"));
        assert!(out.contains("- [x] second task"));
        // the backlog task in the next section is untouched
        assert!(out.contains("## Backlog\n- [ ] later"));
    }

    #[test]
    fn an_epic_never_closes_on_a_pr_alone() {
        // NEGATIVE CONTROL: before this, `ptask done <epic> --proof pr:1` closed it as done.
        let epic = "- [ ] epic(ui): one page <!-- id:ar-1 -->";
        for landed in ["pr:1", "pr:1 pr:2", "https://github.com/a/b/pull/7"] {
            assert!(check_epic_proof(epic, landed).is_err(), "{landed}");
        }
        for seen in [
            "https://agents.example/p",
            "pr:1 run:42",
            "seen live by the human",
        ] {
            assert!(check_epic_proof(epic, seen).is_ok(), "{seen}");
        }
        // Every other row keeps closing on its PR.
        assert!(check_epic_proof("- [ ] fix(ui): a bug", "pr:1").is_ok());
    }

    // A sheet with a roadmap: the open version plus rows aimed at two later ones.
    const ROADMAP: &str = "\
# demo
Version: v1.13.0

## Tasks
- [ ] live one
- [ ] planned one #ai #v1.14.0
- [ ] much later #v1.16.0
";
    const ROADMAP_CUR: Option<V> = Some((1, 13, 0));

    // THE invariant the whole roadmap rests on. `notes board`, `notes ptask list` and the
    // cockpit read the open version through this one function. If a row aimed later ever shows
    // up here, the board starts advertising work that has not started.
    #[test]
    fn the_board_sees_the_open_version_and_none_of_the_roadmap() {
        let dir = std::env::temp_dir().join(format!("ptask-roadmap-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("README.md"), ROADMAP).unwrap();

        let w = current_rows_for_dir(&dir).unwrap();
        let (ver, open): (_, Vec<_>) = (w.version, w.rows.into_iter().map(|r| r.text).collect());
        assert_eq!(ver, "v1.13.0");
        assert_eq!(
            open,
            vec!["- [ ] live one"],
            "planned work is not on the board"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    // An agent board has no `Version:` line: its rows are read against the human sheet's.
    #[test]
    fn an_agent_board_reads_the_parents_version() {
        let dir = std::env::temp_dir().join(format!("ptask-board-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("agent")).unwrap();
        fs::write(dir.join("README.md"), ROADMAP).unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "# demo\n\n## Tasks\n- [ ] now\n- [ ] after #v1.14.0\n",
        )
        .unwrap();

        let w = current_rows_for_dir(&dir.join("agent")).unwrap();
        let (ver, open): (_, Vec<_>) = (w.version, w.rows.into_iter().map(|r| r.text).collect());
        assert_eq!(ver, "v1.13.0");
        assert_eq!(open, vec!["- [ ] now"]);
        let _ = fs::remove_dir_all(&dir);
    }

    // The budget is a day of the weight the agent lane shipped with a PR in the last week: a
    // close with no PR, an old close, and a human-lane close add nothing.
    #[test]
    fn the_board_budget_is_the_weight_shipped_with_a_pr_per_day() {
        let dir = std::env::temp_dir().join(format!("ptask-budget-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("agent")).unwrap();
        let today = chrono::Local::now().date_naive();
        let old = today - chrono::Duration::days(30);
        fs::write(
            dir.join("README.md"),
            format!("# demo\nVersion: v1.0.0\n\n## Tasks\n- [x] human #size/l <!-- pr:9 done:{today} -->\n"),
        )
        .unwrap();
        fs::write(
            dir.join("agent/README.md"),
            format!(
                "# demo\n\n## Tasks\n- [ ] open #size/l\n### Done\n\
- [x] a #size/m <!-- pr:1 done:{today} -->\n\
- [x] b #size/l <!-- pr:2 done:{today} -->\n\
- [x] no pr #size/l <!-- done:{today} -->\n\
- [x] old #size/l <!-- pr:3 done:{old} -->\n"
            ),
        )
        .unwrap();
        let shipped = crate::projects::size_weight("- [x] a #size/m")
            + crate::projects::size_weight("- [x] b #size/l");
        assert_eq!(board_budget(&dir, 7), shipped);
        assert_eq!(board_budget(&dir, 1), shipped.div_ceil(7));
        assert_eq!(board_budget(&dir, 0), 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_move_retags_the_row_where_it_stands() {
        let pick = w("live one");
        let (new, _, line) = retarget(ROADMAP, &pick, (1, 15, 0), ROADMAP_CUR).unwrap();
        assert_eq!(line, "- [ ] live one #v1.15.0");
        assert_eq!(
            new,
            ROADMAP.replace("- [ ] live one\n", "- [ ] live one #v1.15.0\n")
        );
    }

    // Moving a row to the release it is already aimed at matches nothing.
    #[test]
    fn a_move_onto_its_own_version_is_a_no_op() {
        assert!(retarget(ROADMAP, &w("planned one"), (1, 14, 0), ROADMAP_CUR).is_none());
        assert!(retarget(ROADMAP, &w("live one"), (1, 13, 0), ROADMAP_CUR).is_none());
    }

    // NEGATIVE CONTROL for the epic arm: with only the version test, an untagged epic read as
    // the open version and `move --to <open>` matched nothing, so a planned epic could never
    // be aimed at the release in flight. A plain untagged row is already there.
    #[test]
    fn an_untagged_epic_moved_to_the_open_version_takes_its_tag() {
        let sheet = "# demo\nVersion: v1.13.0\n\n## Tasks\n- [ ] feat(x): plain row\n\
                     - [ ] epic(x): the outcome <!-- id:dm-1 -->\n";
        let id = Pick::Id("dm-1".into());
        let (new, _, line) = retarget(sheet, &id, (1, 13, 0), ROADMAP_CUR).unwrap();
        assert_eq!(line, "- [ ] epic(x): the outcome #v1.13.0 <!-- id:dm-1 -->");
        assert!(new.contains(&line), "{new}");
        assert!(retarget(sheet, &w("plain row"), (1, 13, 0), ROADMAP_CUR).is_none());
        assert!(retarget(&new, &id, (1, 13, 0), ROADMAP_CUR).is_none());
        // A loose query never lands on the untagged epic: it would tag a row the words only
        // brushed past on the way to the one meant.
        assert!(retarget(sheet, &w("the outcome"), (1, 13, 0), ROADMAP_CUR).is_none());
    }

    // `move --to` must retag, or the next `sweep` strips the row back to the open version.
    #[test]
    fn a_moved_row_takes_its_new_tag_and_survives_a_sweep() {
        let sheet =
            "# demo\nVersion: v1.13.0\n\n## Tasks\n- [ ] stays\n- [ ] moved #v1.13.0 #urgent\n";
        let (new, _, line) = retarget(sheet, &w("moved"), (1, 14, 0), ROADMAP_CUR).unwrap();
        assert!(
            line.contains("#v1.14.0") && !line.contains("#v1.13.0"),
            "{line}"
        );
        assert!(
            !line.contains("#urgent"),
            "urgent is only legal in the open version: {line}"
        );
        let ctx = project_sweep::Ctx {
            today: chrono::Local::now().date_naive(),
            shape: crate::config::SheetShape::default(),
            open: ROADMAP_CUR,
            rewrite: true,
            systems: vec![],
            tiered: false,
            aim: None,
        };
        let swept = project_sweep::sweep_sheet(&new, &ctx).map_or(new.clone(), |(c, _)| c);
        assert!(
            swept
                .lines()
                .any(|l| l.contains("moved") && l.contains("#v1.14.0")),
            "{swept}"
        );
    }

    #[test]
    fn a_target_must_be_a_version_and_not_behind_the_open_one() {
        assert!(parse_to("next").is_err());
        assert!(parse_to("v1.14").is_err());
        let e = refuse_behind((1, 12, 0), ROADMAP_CUR)
            .unwrap_err()
            .to_string();
        assert!(e.contains("behind the open version v1.13.0"), "{e}");
        assert!(refuse_behind((1, 13, 0), ROADMAP_CUR).is_ok());
        assert!(refuse_behind((0, 0, 1), None).is_ok());
    }

    // THE proof gate. A bare `done` must be refused - if this ever passes, "closed" and
    // "finished" have come apart again and the roll gate above is counting nothing.
    #[test]
    fn an_open_twin_is_found_whatever_its_stamps_and_a_done_one_is_not() {
        let sheet = "## Tasks\n- [ ] fix(x): the thing #c1101 #high <!-- id:ar-1 -->\n- [x] feat(y): shipped #c1101\n";
        assert!(open_twin(sheet, "fix(x): the thing").is_some());
        assert!(open_twin(sheet, "fix(x): the thing, again").is_none());
        assert!(open_twin(sheet, "feat(y): shipped").is_none());
    }

    // A line waiting in `## Inbox` is not filed yet, so it twins nothing: triage files an epic
    // proposal by adding its words while the line itself still waits there.
    #[test]
    fn a_line_waiting_in_the_inbox_is_no_twin() {
        let sheet = "## Inbox\n- [ ] #from/x epic(ui): a pause menu the player opens mid-match\n- [ ] land PR #12\n\n## Tasks\n- [ ] other\n";
        let epic = "epic(ui): a pause menu the player opens mid-match #new";
        assert!(open_twin(
            sheet,
            "#from/x epic(ui): a pause menu the player opens mid-match"
        )
        .is_none());
        assert!(near_twin(sheet, epic).is_none());
        assert!(pr_twin(sheet, "land PR #12").is_none());
        let filed = format!("{sheet}- [ ] {epic} <!-- id:sc-1 -->\n");
        assert!(
            near_twin(&filed, epic).is_some(),
            "the filed row still twins"
        );
    }

    #[test]
    fn done_without_evidence_is_refused() {
        let e = proof_stamp(None, None).unwrap_err().to_string();
        assert!(e.contains("--proof"), "{e}");
        assert!(e.contains("--unverified"), "{e}");
        // blank is not evidence either
        assert!(proof_stamp(Some("  "), None).is_err());
        assert!(proof_stamp(None, Some("")).is_err());
        // and the two doors are alternatives, not a belt-and-braces
        assert!(proof_stamp(Some("pr:1"), Some("why")).is_err());
    }

    #[test]
    fn points_set_the_size_band_and_replace_old_points() {
        let t = |v: &[&str]| v.iter().map(|t| tag_token(t).unwrap()).collect::<Vec<_>>();
        let row = "- [ ] row #size/s #ai <!-- id:ar-1 -->";
        assert_eq!(
            retag(row, &t(&["pts/5"]), &[]),
            "- [ ] row #ai #pts/5 #size/m <!-- id:ar-1 -->",
            "points rewrite the size to their band"
        );
        let scored = "- [ ] row #ai #pts/5 #size/m <!-- id:ar-1 -->";
        assert_eq!(
            retag(scored, &t(&["pts/2"]), &[]),
            "- [ ] row #ai #pts/2 #size/s <!-- id:ar-1 -->",
            "new points replace the old ones, and the band follows"
        );
        assert_eq!(
            retag(scored, &t(&["pts/3"]), &[]),
            "- [ ] row #ai #size/m #pts/3 <!-- id:ar-1 -->",
            "the same band keeps the size where it is"
        );
        assert!(tag_token("pts/4").is_err(), "4 is off the scale");
        assert!(tag_token("pts/x").is_err());
        assert!(
            tag_token("pts/21").is_err(),
            "xl is an epic's #size/, never points"
        );
        assert!(tag_token("pts/+5").is_err(), "digits only");
        assert_eq!(
            tag_token("pts/05").unwrap(),
            "#pts/5",
            "written back canonical"
        );
        assert_eq!(
            retag(scored, &t(&["pts/8", "size/s"]), &[]),
            "- [ ] row #ai #pts/8 #size/l <!-- id:ar-1 -->",
            "points win over a size added beside them"
        );
        assert_eq!(
            retag(scored, &t(&["size/l"]), &[]),
            "- [ ] row #ai #size/l <!-- id:ar-1 -->",
            "a bare resize drops the points it overrides"
        );
        assert_eq!(
            retag(
                "- [ ] row #pts/3 #ai #pts/8 #size/m <!-- id:ar-1 -->",
                &t(&["pts/1"]),
                &[]
            ),
            "- [ ] row #ai #pts/1 #size/s <!-- id:ar-1 -->",
            "every stray points tag goes"
        );
        assert_eq!(
            projects::size_name("- [ ] r #pts/5"),
            Some("m".into()),
            "no size tag: the band"
        );
        assert_eq!(
            projects::size_of("- [ ] r #pts/13 #size/l"),
            Some(13),
            "points are the weight"
        );
        assert_eq!(
            projects::size_of("- [ ] r #size/l"),
            Some(8),
            "no points: the size weighs"
        );
        assert_eq!(
            projects::points_of("- [ ] r #pts/4 #size/m"),
            None,
            "off-scale points are unscored"
        );
    }

    #[test]
    fn a_tag_edit_adds_and_removes_whole_tags_and_keeps_one_size() {
        let row = "- [ ] row #size/s #ai <!-- id:ar-1 -->";
        let t = |v: &[&str]| v.iter().map(|t| tag_token(t).unwrap()).collect::<Vec<_>>();
        assert_eq!(
            retag(row, &t(&["requested"]), &t(&["#ai"])),
            "- [ ] row #size/s #requested <!-- id:ar-1 -->"
        );
        assert_eq!(
            retag(row, &t(&["size/l"]), &[]),
            "- [ ] row #ai #size/l <!-- id:ar-1 -->",
            "a new size replaces the old one"
        );
        assert_eq!(retag(row, &t(&["ai"]), &[]), row, "a tag it has is a no-op");
        let high = "- [ ] row #high #c1105 <!-- id:ar-1 -->";
        assert_eq!(
            retag(high, &t(&["low"]), &[]),
            "- [ ] row #c1105 #low <!-- id:ar-1 -->",
            "a new priority replaces the old one, even a less urgent one"
        );
        assert_eq!(
            retag(high, &t(&["c1107", "C1108", "ai"]), &[]),
            "- [ ] row #high #c1105 #ai <!-- id:ar-1 -->",
            "a stamped row keeps its one created stamp, whatever the case of the new one"
        );
        assert_eq!(
            retag("- [ ] row #high <!-- id:ar-1 -->", &t(&["c1107"]), &[]),
            "- [ ] row #high #c1107 <!-- id:ar-1 -->",
            "a row with no stamp takes one"
        );
        assert_eq!(
            retag("- [ ] row #c1104 #urgent #c1105", &[], &t(&["c1105"])),
            "- [ ] row #c1104 #urgent",
            "--remove clears a stray stamp"
        );
        assert_eq!(
            carry_tags(high, "fix(x): reworded #urgent"),
            "fix(x): reworded #urgent #c1105",
            "a rewrite's priority replaces the row's"
        );
        assert!(tag_token("v0.2.0")
            .unwrap_err()
            .to_string()
            .contains("move"));
        assert!(tag_token("two words").is_err());
        assert!(tag_token("#").is_err());
    }

    #[test]
    fn close_day_takes_a_past_day_and_refuses_a_future_or_malformed_one() {
        let today = chrono::Local::now().date_naive();
        assert_eq!(close_day(None).unwrap(), today);
        let past = chrono::NaiveDate::from_ymd_opt(2026, 10, 3).unwrap();
        assert_eq!(close_day(Some("2026-10-03")).unwrap(), past);
        let next = (today + chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        assert!(close_day(Some(&next))
            .unwrap_err()
            .to_string()
            .contains("future"));
        assert!(close_day(Some("last week")).is_err());
    }

    #[test]
    fn done_stamps_the_day_it_closed_and_reads_it_back() {
        let day = chrono::NaiveDate::from_ymd_opt(2026, 11, 5).unwrap();
        let row = md::add_marker("- [x] shipped <!-- id:ar-1 -->", &done_token(day));
        assert_eq!(row, "- [x] shipped <!-- id:ar-1 done:2026-11-05 -->");
        assert_eq!(done_on(&row), Some(day));
        assert_eq!(done_on("- [x] shipped <!-- done:soon -->"), None);
    }

    #[test]
    fn both_doors_produce_a_stamp_and_the_unverified_one_says_so() {
        assert_eq!(proof_stamp(Some("pr:1142"), None).unwrap(), "pr:1142");
        assert_eq!(
            proof_stamp(None, Some("no staging seed")).unwrap(),
            "unverified: no staging seed"
        );
    }

    // The stamp joins whatever marker the line already carries rather than opening a
    // second comment - `id:`/`ask:` readers scan inside the one comment.
    #[test]
    fn the_stamp_merges_into_an_existing_marker() {
        let line = "- [ ] facility save 400 #ai <!-- id:pmp-602 -->";
        let out = md::add_marker(&md::set_checkbox(line, 'x'), "pr:1142");
        assert_eq!(
            out,
            "- [x] facility save 400 #ai <!-- id:pmp-602 pr:1142 -->"
        );
        assert_eq!(out.matches("<!--").count(), 1);
    }

    #[test]
    fn the_stamp_opens_a_marker_on_a_bare_line() {
        let out = md::add_marker("- [x] plain task", "unverified: no artifact");
        assert_eq!(out, "- [x] plain task <!-- unverified: no artifact -->");
    }

    // A catch-all sheet and one of the per-project sheets it is being split into.
    const SRC: &str = "\
# unity-playground
Version: v0.4.0

## Tasks
- [ ] playground thing #high
- [ ] dodgeball spawn bug #v0.4.0 #urgent #game <!-- since:2026-10-01 carried:2 -->
- [ ] dodgeball menu polish #low
- [ ] dodgeball netcode #v0.5.0 #high
";

    const DEST: &str = "\
# dodginballs
Version: v1.2.0

## Tasks
- [ ] existing row #high
- [ ] later row #v1.3.0 #high
";

    const SRC_CUR: Option<V> = Some((0, 4, 0));

    fn lift(pick: &Pick, to: Option<V>) -> Result<Option<Lifted>> {
        lift_into(SRC, DEST, pick, to, Some((1, 2, 0)), &HashSet::new())
    }

    #[test]
    fn a_move_drops_an_of_naming_no_row_in_the_destination_and_keeps_one_it_holds() {
        let src = SRC.replace("menu polish #low", "menu polish #low #of/ar-9");
        let lifted = |held: &[&str]| {
            let held = held.iter().map(|s| s.to_string()).collect();
            let m = lift_into(&src, DEST, &w("menu polish"), None, None, &held)
                .unwrap()
                .unwrap();
            (m.line, m.unlinked)
        };
        assert_eq!(
            lifted(&[]),
            (
                "- [ ] dodgeball menu polish #low".into(),
                Some("ar-9".into())
            )
        );
        assert_eq!(
            lifted(&["ar-9"]),
            ("- [ ] dodgeball menu polish #low #of/ar-9".into(), None)
        );
    }

    #[test]
    fn a_cross_project_move_lands_on_the_dest_with_no_tag() {
        let m = lift(&w("spawn bug"), None).unwrap().unwrap();
        // The source's tag goes; priority, other tags and the marker stay.
        assert_eq!(
            m.line,
            "- [ ] dodgeball spawn bug #urgent #game <!-- since:2026-10-01 carried:2 -->"
        );
        assert!(
            !m.src.contains("spawn bug"),
            "row must leave SRC:\n{}",
            m.src
        );
        assert!(m.src.contains("- [ ] dodgeball menu polish #low"));
        let open: Vec<_> = sheet::open_rows(&m.dest)
            .into_iter()
            .map(|(_, l)| l)
            .collect();
        assert!(open.contains(&m.line.as_str()), "{}", m.dest);
        assert!(m.dest.contains("- [ ] existing row #high"));
    }

    #[test]
    fn a_cross_project_move_carries_the_rows_detail_lines_and_children() {
        let src = SRC.replace(
            "- [ ] dodgeball spawn bug #v0.4.0 #urgent #game <!-- since:2026-10-01 carried:2 -->\n",
            "- [ ] dodgeball spawn bug #high\n  was: the spawn is off\n  - [ ] a child row\n",
        );
        let m = lift_into(
            &src,
            DEST,
            &w("spawn bug"),
            None,
            Some((1, 2, 0)),
            &HashSet::new(),
        )
        .unwrap()
        .unwrap();
        assert!(
            m.dest.contains(
                "- [ ] dodgeball spawn bug #high\n  was: the spawn is off\n  - [ ] a child row\n"
            ),
            "{}",
            m.dest
        );
        assert!(
            !m.src.contains("spawn") && !m.src.contains("child row"),
            "{}",
            m.src
        );
        assert!(
            m.src
                .contains("- [ ] playground thing #high\n- [ ] dodgeball menu polish #low\n"),
            "{}",
            m.src
        );
    }

    #[test]
    fn a_cross_project_move_with_to_is_aimed_at_that_release() {
        let m = lift(&w("spawn"), Some((1, 3, 0))).unwrap().unwrap();
        // #urgent is only legal in the open version, the same rule the same-sheet move applies.
        assert_eq!(
            m.line,
            "- [ ] dodgeball spawn bug #game #high #v1.3.0 <!-- since:2026-10-01 carried:2 -->"
        );
        assert!(m.dest.lines().any(|l| l == m.line), "{}", m.dest);
    }

    // The source search spans every release, as the same-sheet move's does.
    #[test]
    fn a_cross_project_move_finds_a_row_aimed_later_on_the_source() {
        let m = lift(&w("netcode"), None).unwrap().unwrap();
        assert_eq!(m.line, "- [ ] dodgeball netcode #high");
    }

    #[test]
    fn a_cross_project_move_refuses_a_dest_with_no_section() {
        let prose = "# prose only\n\nnothing here\n";
        assert!(lift_into(SRC, prose, &w("spawn"), None, None, &HashSet::new()).is_err());
    }

    #[test]
    fn a_cross_project_move_with_no_match_is_none() {
        assert!(lift(&w("no such row"), None).unwrap().is_none());
        // A closed row is not movable.
        let closed = SRC.replace("- [ ] dodgeball menu", "- [x] dodgeball menu");
        assert!(lift_into(
            &closed,
            DEST,
            &w("menu polish"),
            None,
            None,
            &HashSet::new()
        )
        .unwrap()
        .is_none());
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ptask-xproj-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn row_ids_reads_both_sheets_and_their_version_notes() {
        let d = scratch("ids");
        fs::create_dir_all(d.join("agent/versions")).unwrap();
        fs::write(d.join("README.md"), "## Tasks\n- [ ] a <!-- id:hc-1 -->\n").unwrap();
        fs::write(
            d.join("agent/README.md"),
            "## Tasks\n- [ ] b <!-- id:hc-2 -->\n",
        )
        .unwrap();
        fs::write(
            d.join("agent/versions/v0.1.0.md"),
            "## Tasks\n- [x] c <!-- id:hc-3 -->\n",
        )
        .unwrap();
        let mut ids: Vec<_> = row_ids(&d).into_iter().collect();
        ids.sort();
        assert_eq!(ids, ["hc-1", "hc-2", "hc-3"]);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn transfer_writes_both_sheets() {
        let d = scratch("ok");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let m = transfer(&s, &t, &w("spawn"), None, &HashSet::new())
            .unwrap()
            .unwrap();
        // Written swept: the same rows as returned, laid out in sections.
        let (src, dest) = (
            fs::read_to_string(&s).unwrap(),
            fs::read_to_string(&t).unwrap(),
        );
        let open = |c: &str| {
            let mut v: Vec<String> = c
                .lines()
                .filter(|l| md::is_open_task(l) && !md::is_empty_unchecked(l))
                .map(md::task_text)
                .collect();
            v.sort();
            v
        };
        assert_eq!(open(&src), open(&m.src));
        assert_eq!(open(&dest), open(&m.dest));
        assert!(!src.contains("spawn") && dest.contains("spawn"));
        let _ = fs::remove_dir_all(&d);
    }

    // Every refusal must leave both sheets byte-identical.
    #[test]
    fn transfer_refusals_write_nothing() {
        let d = scratch("refuse");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let same = transfer(&s, &s, &w("spawn"), None, &HashSet::new())
            .unwrap_err()
            .to_string();
        assert!(same.contains("same sheet"), "{same}");
        assert!(transfer(&s, &t, &w("spawn"), Some("next"), &HashSet::new()).is_err());
        assert!(transfer(&s, &t, &w("no such row"), None, &HashSet::new())
            .unwrap()
            .is_none());
        assert_eq!(fs::read_to_string(&s).unwrap(), SRC);
        assert_eq!(fs::read_to_string(&t).unwrap(), DEST);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_same_project_move_keeps_the_row_in_place() {
        let (new, _, line) = retarget(SRC, &w("spawn"), (0, 5, 0), SRC_CUR).unwrap();
        assert_eq!(
            line,
            "- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->"
        );
        assert_eq!(
            new,
            "# unity-playground\nVersion: v0.4.0\n\n## Tasks\n- [ ] playground thing #high\n- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->\n- [ ] dodgeball menu polish #low\n- [ ] dodgeball netcode #v0.5.0 #high\n"
        );
    }

    // `start` sets and `unstart` clears; neither flips a row already where it was asked to
    // be (lesson 2748: a toggle run twice undid the first start).
    #[test]
    fn start_sets_and_never_toggles() {
        let (out, _) = md::edit_first_in_section(
            SHEET,
            sheet::TASKS,
            |l| is_match(l, "first"),
            |l| Some(started(l, None)),
        )
        .unwrap();
        assert!(out.contains("- [/] first task"));
        assert!(md::is_in_progress("- [/] a") && !md::is_in_progress("- [ ] a"));
    }

    // The join between a queue item and its row: the first start gives the row its id, and
    // a row that already has one keeps it.
    #[test]
    fn a_row_going_to_started_gets_its_id_once() {
        let line = started("- [ ] fix(a): thing #high", Some("ar-7"));
        assert_eq!(line, "- [/] fix(a): thing #high <!-- id:ar-7 -->");
        let back = md::set_checkbox(&line, ' ');
        assert_eq!(
            started(&back, Some("ar-8")),
            "- [/] fix(a): thing #high <!-- id:ar-7 -->"
        );
        assert_eq!(
            started("- [ ] a <!-- carried:1 -->", Some("ar-9")),
            "- [/] a <!-- carried:1 id:ar-9 -->"
        );
        // No code, no id: the row still starts, and the caller decides what that means.
        assert_eq!(started("- [ ] a", None), "- [/] a");
    }

    #[test]
    fn a_second_row_landing_the_same_pr_is_a_twin_whatever_its_type_and_words() {
        let board = "## Tasks\n\
            - [ ] feat(gameplay): land PR #2539 (branch agent-1-261113-225413, plan #size/m <!-- id:ucp-2190 -->\n\
            - [ ] feat(netcode): Re-gate and land PR #2827 (branch agent-4, Net3DPlayTests ping #pts/3 <!-- id:ucp-2524 -->\n\
            - [ ] feat(gameplay): Land acme/game#2630 (branch agent-5 <!-- id:ucp-2337 -->\n\
            - [ ] fix(ci): train.py has no path for a green-gated train (#2620 on 11-14: a flake) <!-- id:ucp-2333 -->\n\
            - [ ] chore(ci): verify the nightly after the merge #pr/acme/game/2700 <!-- id:ucp-2340 -->\n\
            - [ ] fix(git): merge #812 conflict markers left in the README <!-- id:ucp-2341 -->\n\
            - [x] chore(ci): land PR #1000 <!-- id:ucp-9 -->\n";
        let twin = |t: &str| pr_twin(board, t).map(|(l, n)| (md::row_id(l).unwrap(), n));
        let id = |s: &str, n: u64| Some((s.to_string(), n));
        assert_eq!(
            twin("feat(ci): land PR #2539 (branch agent-1, plan"),
            id("ucp-2190", 2539)
        );
        assert_eq!(
            twin("fix(ci): re-gate and land PR #2539 (worktree"),
            id("ucp-2190", 2539)
        );
        assert_eq!(
            twin("fix(netcode): Land #2827 (Net3D ping fix)"),
            id("ucp-2524", 2827)
        );
        assert_eq!(
            twin("chore(ci): regate #2827 after aws-burst-1"),
            id("ucp-2524", 2827)
        );
        assert_eq!(
            twin("feat(look): Re-gate and land acme/game#2630"),
            id("ucp-2337", 2630)
        );
        assert_eq!(
            twin("chore(ci): land PR 2827, held by the slot"),
            id("ucp-2524", 2827)
        );
        assert_eq!(
            twin("chore(ci): land PR#2539"),
            id("ucp-2190", 2539),
            "PR glued to its number"
        );
        assert_eq!(
            twin("chore(ci): land PR #2630"),
            None,
            "one row names a repo and the other does not: kept apart"
        );
        assert_eq!(
            twin("chore(ci): land PR #2700"),
            None,
            "a #pr/ tag gates a row on the PR; it does not land it"
        );
        assert_eq!(
            twin("chore(ci): land PR #812"),
            None,
            "merge is not a landing verb"
        );
        assert_eq!(
            twin("fix(ci): re-gate and land PR #2620"),
            None,
            "#2620 is only cited"
        );
        assert_eq!(twin("chore(ci): land PR #1000"), None, "a closed row");
        assert_eq!(
            twin("feat(ci): land other-repo#2630"),
            None,
            "another repo's #2630: both rows name a repo and they differ"
        );
        assert_eq!(
            twin("fix(ci): the gate reads #2539 as stale"),
            None,
            "does not land it"
        );
    }

    #[test]
    fn landed_pr_reads_the_landing_phrases() {
        let pr = |l: &str| landed_pr(&format!("- [ ] {l}"));
        assert_eq!(
            pr("feat(ci): Land platform PR #1594 (branch x)"),
            Some((Some("platform".into()), 1594))
        );
        assert_eq!(
            pr("chore(ci): land train #2230: #2217 #2218"),
            Some((None, 2230))
        );
        assert_eq!(
            pr("fix(ci): re-land #440 KillMode=mixed"),
            Some((None, 440))
        );
        assert_eq!(
            pr("chore(ci): land ucp-1777 (PR #2266), Checks refused"),
            Some((Some("ucp-1777".into()), 2266)),
            "the word before PR qualifies it"
        );
        assert_eq!(pr("docs(ci): land the ci.md note (#1997)"), None);
        assert_eq!(
            pr("chore(ci): land #12 #pr/owner/repo/12"),
            Some((None, 12))
        );
        assert_eq!(pr("feat(x): y #pr/owner/repo/12"), None, "a gate tag alone");
        assert_eq!(pr("chore(ci): land PR #abc then #5"), None);
    }

    #[test]
    fn a_near_duplicate_is_the_same_type_and_most_title_words() {
        let board = "## Tasks\n- [ ] fix(ui): the pause menu flickers on resume #size/s <!-- id:sc-4 -->\n- [x] fix(ui): closed rows are never twins of anything\n";
        assert!(
            near_twin(board, "fix(ui): Pause menu flickers on resume #size/m").is_some(),
            "4 of 5 words shared, case and tags aside"
        );
        assert!(
            near_twin(
                board,
                "fix(ui): pause menu flickers on resume again #size/s"
            )
            .is_none(),
            "4 of 6 is under the bar: a false twin would drop a real row"
        );
        assert!(
            near_twin(board, "feat(ui): pause menu flickers on resume #size/s").is_none(),
            "another type"
        );
        assert!(
            near_twin(board, "fix(ui): pause menu crashes on load #size/s").is_none(),
            "half the words"
        );
        assert!(
            near_twin(board, "fix(ui): closed rows are never twins of anything").is_none(),
            "a closed row"
        );
        assert!(
            near_twin(
                board,
                "fix(menu): the pause menu flickers on resume #size/s"
            )
            .is_some(),
            "triage re-scoped the area: the same words in another area are still the row"
        );
        assert!(
            near_twin(board, "fix(menu): the pause menu crashes on load #size/s").is_none(),
            "another area and other words file"
        );
        let kpi = "## Tasks\n- [ ] check(kpi): no_pr_rate past threshold: 7d 0.3 (28d 0.2, max 0.1) #size/s\n";
        assert!(
            near_twin(
                kpi,
                "check(kpi): retry_rate past threshold: 7d 0.5 (28d 0.4, max 0.2) #size/s"
            )
            .is_none(),
            "templated rows for two KPIs are two rows"
        );
        let unit = "## Tasks\n- [ ] fix(unit): agentctl@inbox-plan.service failed: exit 1, see the journal #size/s\n";
        assert!(
            near_twin(
                unit,
                "fix(recovery): agentctl@nightly-measure.service failed: exit 1, see the journal #size/s"
            )
            .is_none(),
            "a templated row for another unit files, whatever its area"
        );
        assert!(
            near_twin(
                unit,
                "fix(recovery): agentctl@inbox-plan.service failed: exit 1, see the journal #size/s"
            )
            .is_some(),
            "the same unit re-scoped is still the row"
        );
        let watch = "## Tasks\n- [ ] check(recovery): watch claude-spend-hourly is red; fix: read where the red is watched, fix the cause #size/s\n";
        assert!(
            near_twin(
                watch,
                "check(telemetry): watch source-pace is red; fix: read where the red is watched, fix the cause #size/s"
            )
            .is_none(),
            "a hyphenated watch name is a name"
        );
        let queue = "## Tasks\n- [ ] check(kpi): queue 12m old, 3 checks failing on agent-runtime; read the dispatch log and fix the oldest cause #size/s\n";
        assert!(
            near_twin(
                queue,
                "check(kpi): queue 15m old, 3 checks failing on agent-runtime; read the dispatch log and fix the oldest cause #size/s"
            )
            .is_some(),
            "a row whose readings moved is still the row"
        );
        let names = |t: &str| {
            let mut n: Vec<String> = names(&format!("- [ ] {t}")).into_iter().collect();
            n.sort();
            n
        };
        assert_eq!(
            names("fix(x): 2 checks, 7d 0.3, 3/5, -3 and 12:30 on b1 via claude:sonnet 2026-11-21"),
            ["2026-11-21", "b1", "claude:sonnet"],
            "counts, readings, ratios, signs and times are not names; builds, lanes and dates are"
        );
    }

    // Ids never come back after the row that held the highest one leaves the project.
    #[test]
    fn the_id_high_water_outlives_the_row_that_set_it() {
        let dir = std::env::temp_dir().join(format!("ptask-hw-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        note_ids(&dir, &["- [ ] a <!-- id:ar-41 -->".to_string()]).unwrap();
        note_ids(&dir, &["- [ ] b <!-- id:ar-7 -->".to_string()]).unwrap();
        assert_eq!(fs::read_to_string(dir.join(IDS)).unwrap(), "id:ar-41\n");
        assert_eq!(
            next_id(&dir, "ar"),
            "ar-42",
            "no sheet holds ar-41 any more"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    const BOARD: &str = "\
# demo - agent board
Version: v0.0.1

## Tasks
- [ ] open row #high
- [x] shipped row #high <!-- pr:12 -->
  - with a note under it
- [ ] open parent
  - [x] a done subtask stays with its parent
- [x] second shipped row
";

    #[test]
    fn done_rows_are_top_level_checked_rows_with_their_children() {
        let lines: Vec<&str> = BOARD.lines().collect();
        let rows: Vec<Vec<&str>> = done_rows(BOARD)
            .into_iter()
            .map(|r| lines[r].to_vec())
            .collect();
        assert_eq!(
            rows,
            vec![
                vec![
                    "- [x] shipped row #high <!-- pr:12 -->",
                    "  - with a note under it"
                ],
                vec!["- [x] second shipped row"],
            ]
        );
    }

    #[test]
    fn done_rows_join_the_end_of_their_section() {
        let note = "# n\n\n## Notes\n";
        let once = append_done_rows(note, "Done rows", &["- [x] one".to_string()]);
        assert!(
            once.ends_with("## Notes\n\n## Done rows\n- [x] one\n"),
            "{once}"
        );
        let twice = append_done_rows(&once, "Done rows", &["- [x] two".to_string()]);
        assert!(
            twice.ends_with("## Done rows\n- [x] one\n- [x] two\n"),
            "{twice}"
        );
    }

    #[test]
    fn archive_moves_done_rows_to_the_versions_note_the_proof_is_in() {
        let root = std::env::temp_dir().join(format!("ptask-archive-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut p = crate::config::test_profile(&root.to_string_lossy());
        let projects = root.join("lab/projects/current");
        let dir = projects.join("demo");
        fs::create_dir_all(dir.join("agent")).unwrap();
        let index = root.join("lab/projects/index.md");
        fs::write(
            &index,
            "## Current\n- [[lab/projects/current/demo/summary|demo]]\n",
        )
        .unwrap();
        fs::write(dir.join("summary.md"), "# demo\n").unwrap();
        fs::write(
            dir.join("README.md"),
            "# demo\nVersion: v0.3.0 #beta\n\n## Tasks\n- [ ] human row\n",
        )
        .unwrap();
        // A closed row archived with a tier token left on it goes into the note without one.
        let board = BOARD.replace("<!-- pr:12 -->", "<!-- pr:12 tier:backlog -->");
        fs::write(dir.join("agent/README.md"), &board).unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);

        assert!(archive(&p, &log, "demo", false, Lane::Human).is_err());
        archive(&p, &log, "demo", true, Lane::Agent).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("agent/README.md")).unwrap(),
            board
        );

        archive(&p, &log, "demo", false, Lane::Agent).unwrap();
        let board = fs::read_to_string(dir.join("agent/README.md")).unwrap();
        assert_eq!(
            board,
            "# demo - agent board\nVersion: v0.0.1\n\n## Tasks\n### Board\n- [ ] open row #high\n- [ ] open parent\n  - [x] a done subtask stays with its parent\n- [ ] \n\n---\n### Done\n"
        );
        let note = fs::read_to_string(dir.join("agent/versions/v0.3.0.md")).unwrap();
        assert!(
            note.ends_with("## Done rows\n- [x] shipped row #high <!-- pr:12 -->\n  - with a note under it\n- [x] second shipped row\n"),
            "{note}"
        );
        // nothing left to move is not an error
        assert_eq!(archive(&p, &log, "demo", false, Lane::Agent).unwrap(), 0);
        let _ = fs::remove_dir_all(&root);
    }

    /// A project dir with a human sheet at `version` and an agent board; `root` is wiped first.
    fn board_project(tag: &str, version: &str) -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("ptask-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dir = root.join("demo");
        fs::create_dir_all(dir.join("agent")).unwrap();
        fs::write(
            dir.join("README.md"),
            format!("# demo\nVersion: {version} #beta\n\n## Tasks\n- [ ] human row\n"),
        )
        .unwrap();
        (root, dir)
    }

    const OLD_DONE_BOARD: &str = "# demo - agent board\n\n## Tasks\n- [ ] open row\n- [x] shipped long ago <!-- id:d-1 done:2020-01-01 pr:x/y#1 -->\n";

    // The roll-off of the agent board files the closed row in the human sheet's open version,
    // the note the window reads, not in v0.0.1 because the board has no Version line.
    #[test]
    fn an_agent_board_roll_off_lands_in_the_open_versions_note() {
        let (root, dir) = board_project("rolloff", "v0.3.0");
        let ctx = sweep_ctx(&dir, Lane::Agent, OLD_DONE_BOARD, false);
        assert_eq!(ctx.open, Some((0, 3, 0)));
        let t = tidy(&dir, "demo", Lane::Agent, OLD_DONE_BOARD, &ctx, None, false).unwrap();
        assert_eq!(t.archived, 1);
        let note = fs::read_to_string(dir.join("agent/versions/v0.3.0.md")).unwrap();
        assert!(note.contains("id:d-1"), "{note}");
        assert!(!dir.join("agent/versions/v0.0.1.md").exists());
        // the window's closed count reads the note through `note_done_rows`
        let closed = note_done_rows(&note);
        assert!(closed.iter().any(|l| l.contains("id:d-1")), "{closed:?}");
        let _ = fs::remove_dir_all(&root);
    }

    // A done row aimed at a later version waits on the board for it, as on the human sheet.
    #[test]
    fn an_agent_board_keeps_a_done_row_aimed_at_a_later_version() {
        let (root, dir) = board_project("later", "v0.3.0");
        let board =
            format!("{OLD_DONE_BOARD}- [x] later one #v0.4.0 <!-- id:d-2 done:2020-01-01 -->\n");
        let ctx = sweep_ctx(&dir, Lane::Agent, &board, false);
        let t = tidy(&dir, "demo", Lane::Agent, &board, &ctx, None, false).unwrap();
        assert_eq!(t.archived, 1);
        assert!(t.content.contains("id:d-2") && !t.content.contains("id:d-1"));
        let _ = fs::remove_dir_all(&root);
    }

    // Negative control: a project whose open version is v0.0.1 still archives into v0.0.1.
    #[test]
    fn a_project_at_v0_0_1_still_archives_into_v0_0_1() {
        let (root, dir) = board_project("v001", "v0.0.1");
        let ctx = sweep_ctx(&dir, Lane::Agent, OLD_DONE_BOARD, false);
        assert_eq!(ctx.open, Some((0, 0, 1)));
        tidy(&dir, "demo", Lane::Agent, OLD_DONE_BOARD, &ctx, None, false).unwrap();
        let note = fs::read_to_string(dir.join("agent/versions/v0.0.1.md")).unwrap();
        assert!(note.contains("id:d-1"), "{note}");
        let _ = fs::remove_dir_all(&root);
    }

    // The rows misfiled into v0.0.1 since the window opened move to the open note; older ones,
    // rows with no day, and a project at v0.0.1 stay.
    #[test]
    fn rehome_moves_only_the_rows_closed_since_the_window_opened() {
        let (root, dir) = board_project("rehome", "v0.3.0");
        let versions = dir.join("agent/versions");
        fs::create_dir_all(&versions).unwrap();
        fs::create_dir_all(dir.join("sprints")).unwrap();
        fs::write(
            dir.join("sprints/v0.3.0.md"),
            "# demo v0.3.0 sprint\n\n## Committed\n<!-- window: opened=2026-11-19 due=2026-11-19 -->\n- a row <!-- id:c-1 -->\n<!-- /window -->\n",
        )
        .unwrap();
        fs::write(
            versions.join("v0.0.1.md"),
            "# demo v0.0.1 - agent notes\n\n## Notes\n\n## Done rows\n- [x] old <!-- id:o-1 done:2026-11-01 -->\n- [x] new <!-- id:n-1 done:2026-11-19 -->\n  - a child line\n- [x] undated <!-- id:u-1 -->\n",
        )
        .unwrap();
        assert_eq!(rehome_rows(&dir, "demo", true).unwrap(), 1);
        assert!(fs::read_to_string(versions.join("v0.0.1.md"))
            .unwrap()
            .contains("id:n-1"));
        assert_eq!(rehome_rows(&dir, "demo", false).unwrap(), 1);
        let from = fs::read_to_string(versions.join("v0.0.1.md")).unwrap();
        assert!(from.contains("id:o-1") && from.contains("id:u-1"), "{from}");
        assert!(
            !from.contains("id:n-1") && !from.contains("a child line"),
            "{from}"
        );
        let to = fs::read_to_string(versions.join("v0.3.0.md")).unwrap();
        assert!(
            to.contains("id:n-1") && to.contains("  - a child line"),
            "{to}"
        );
        // a second run has nothing left to move
        assert_eq!(rehome_rows(&dir, "demo", false).unwrap(), 0);
        let _ = fs::remove_dir_all(&root);
    }

    // A false close undone: the row opens again with its proof off, in place on the board or
    // moved back from the version note it was archived into, its detail lines with it.
    #[test]
    fn reopen_undoes_a_close_on_the_board_and_from_the_archive() {
        let root = std::env::temp_dir().join(format!("ptask-reopen-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut p = crate::config::test_profile(&root.to_string_lossy());
        let projects = root.join("lab/projects/current");
        let dir = projects.join("demo");
        fs::create_dir_all(dir.join("agent/versions")).unwrap();
        let index = root.join("lab/projects/index.md");
        fs::write(
            &index,
            "## Current\n- [[lab/projects/current/demo/summary|demo]]\n",
        )
        .unwrap();
        fs::write(dir.join("summary.md"), "# demo\n").unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "# demo - agent board\n\n## Tasks\n- [ ] fix(a): open #size/s <!-- id:dm-1 -->\n- [x] fix(b): closed done:2026 #size/s <!-- id:dm-2 done:2026-11-07 pr:652 commit:24d818eb99fc -->\n",
        )
        .unwrap();
        fs::write(
            dir.join("agent/versions/v0.1.0.md"),
            "# demo v0.1.0\n\n## Done rows\n- [x] fix(c): kept #size/s <!-- id:dm-3 done:2026-11-06 pr:9 -->\n- [x] fix(d): wrong #size/m <!-- id:dm-4 done:2026-11-07 unverified: no pr -->\n  - a detail under it\n- [x] fix(e): dropped #size/s <!-- id:dm-5 dropped: stale -->\n",
        )
        .unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);

        assert!(
            reopen(&p, &log, "demo", "dm-2", " ", Lane::Agent).is_err(),
            "a why is required"
        );
        assert!(
            reopen(&p, &log, "demo", "two", "x", Lane::Agent).is_err(),
            "an id is required"
        );
        assert_eq!(
            reopen(&p, &log, "demo", "dm-1", "x", Lane::Agent).unwrap(),
            1,
            "an open row is not closed"
        );
        assert_eq!(
            reopen(&p, &log, "demo", "dm-2", "wrong PR", Lane::Human).unwrap(),
            0,
            "an agent board row reopens without --agent: the id names one row in either lane"
        );
        assert_eq!(
            reopen(&p, &log, "demo", "dm-4", "wrong PR", Lane::Agent).unwrap(),
            0,
            "an archived row reopens on its own lane"
        );
        let board = fs::read_to_string(dir.join("agent/README.md")).unwrap();
        assert_eq!(
            board,
            "# demo - agent board\n\n## Tasks\n### Board\n- [ ] fix(d): wrong #size/m <!-- id:dm-4 -->\n  - a detail under it\n- [ ] fix(a): open #size/s <!-- id:dm-1 -->\n- [ ] fix(b): closed done:2026 #size/s <!-- id:dm-2 -->\n- [ ] \n\n---\n### Done\n"
        );
        let note = fs::read_to_string(dir.join("agent/versions/v0.1.0.md")).unwrap();
        assert_eq!(
            note,
            "# demo v0.1.0\n\n## Done rows\n- [x] fix(c): kept #size/s <!-- id:dm-3 done:2026-11-06 pr:9 -->\n- [x] fix(e): dropped #size/s <!-- id:dm-5 dropped: stale -->\n"
        );
        assert_eq!(unclose("- [x] t <!-- done:2026-11-07 pr:1 -->"), "- [ ] t");
        assert_eq!(
            unclose("- [x] t <!-- id:a-1 done:2026-11-07 pr:1 --> #low"),
            "- [ ] t <!-- id:a-1 --> #low",
            "text after the marker stays, and the row is never dropped"
        );
        let _ = fs::remove_dir_all(&root);
    }

    // An id is never reused: the max is taken over both lanes and the archive, and a dropped
    // row keeps its id on the sheet.
    #[test]
    fn next_id_is_one_past_the_highest_id_anywhere_in_the_project() {
        let dir = std::env::temp_dir().join(format!("ptask-ids-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("agent")).unwrap();
        fs::create_dir_all(dir.join("versions")).unwrap();
        assert_eq!(next_id(&dir, "ar"), "ar-1", "an empty project starts at 1");
        fs::write(dir.join("README.md"), "- [ ] a <!-- id:ar-3 -->\n").unwrap();
        fs::write(
            dir.join("agent/README.md"),
            "- [x] b <!-- id:ar-9 dropped: stale -->\n",
        )
        .unwrap();
        fs::write(
            dir.join("versions/v0.1.0.md"),
            "- [x] c <!-- id:ar-12 pr:4 -->\n",
        )
        .unwrap();
        fs::write(dir.join("notes.txt"), "id:ar-99 is not on a sheet\n").unwrap();
        fs::write(
            dir.join("other.md"),
            "- [ ] d <!-- id:bar-40 id:xar-41 -->\n",
        )
        .unwrap();
        assert_eq!(next_id(&dir, "ar"), "ar-13");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_drop_says_why_or_names_its_duplicate_never_both() {
        assert_eq!(drop_stamp(Some("stale"), None).unwrap(), "dropped: stale");
        assert_eq!(drop_stamp(None, Some("ar-142")).unwrap(), "dup:ar-142");
        assert!(drop_stamp(None, None).is_err(), "a drop with no reason");
        assert!(drop_stamp(Some("x"), Some("ar-1")).is_err(), "both");
        assert!(
            drop_stamp(None, Some("the other one")).is_err(),
            "--dup takes an id"
        );
        assert!(
            drop_stamp(Some("  "), None).is_err(),
            "a blank reason is no reason"
        );
    }

    #[test]
    fn an_id_shaped_query_picks_that_row_and_no_other() {
        let pick = w("AR-14");
        assert!(matches!(pick, Pick::Id(ref id) if id == "ar-14"));
        assert!(pick.hits("- [ ] fix(a): b #high <!-- id:ar-14 -->"));
        assert!(pick.hits("- [/] fix(a): b #high <!-- id:ar-14 pr:3 -->"));
        assert!(
            !pick.hits("- [ ] fix(a): b #high <!-- id:ar-142 -->"),
            "a prefix"
        );
        assert!(
            !pick.hits("- [x] fix(a): b #high <!-- id:ar-14 -->"),
            "closed"
        );
        assert!(
            !pick.hits("- [ ] see ar-14 for the cause #high"),
            "text is not an id"
        );
        assert!(matches!(w("inotify"), Pick::Words(_)));
    }
}

#[cfg(test)]
mod inbox_tests {
    use super::*;

    struct Vault {
        root: PathBuf,
        p: Profile,
        log: Logger,
    }

    impl Drop for Vault {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    impl Vault {
        fn sheet(&self) -> PathBuf {
            self.root.join("projects/scratch/README.md")
        }
        fn read(&self) -> String {
            fs::read_to_string(self.sheet()).unwrap()
        }
    }

    #[test]
    fn edit_text_keeps_the_parent_and_refuses_another() {
        let v = vault(
            "parent",
            "",
            "- [ ] fix(ui): the menu flickers #high #of/sc-9 <!-- id:sc-1 -->\n",
        );
        let one = Pick::Id("sc-1".into());
        let w = Writer::of(None, None, None, None, &[], false, Vec::new());
        let go = |text: &str| {
            retext(
                &v.p,
                &v.log,
                "scratch",
                &one,
                Some(text),
                None,
                &[],
                false,
                None,
                Lane::Human,
                &w,
            )
        };
        // nc-108: the same link retyped lands once
        go("fix(ui): the menu blinks #of/sc-9").unwrap();
        let sheet = v.read();
        assert_eq!(sheet.matches("#of/sc-9").count(), 1, "{sheet}");
        // a different parent is refused, not dropped in silence
        let err = go("fix(ui): the menu blinks #of/sc-4")
            .unwrap_err()
            .to_string();
        assert!(err.contains("--remove of/sc-9 --add of/sc-4"), "{err}");
        assert_eq!(v.read(), sheet, "nothing was edited");
    }

    #[test]
    fn row_writes_leave_a_record_with_id_words_and_lane() {
        let v = vault(
            "record",
            "",
            "- [ ] fix(ui): the menu flickers #high <!-- id:sc-1 -->\n\
             - [ ] fix(ui): the sound is late #low <!-- id:sc-2 -->\n",
        );
        let one = Pick::Id("sc-1".into());
        let new = Some("fix(ui): the menu blinks #high");
        retext(
            &v.p,
            &v.log,
            "scratch",
            &one,
            new,
            None,
            &[],
            false,
            None,
            Lane::Human,
            &Writer::of(None, None, None, None, &[], false, Vec::new()),
        )
        .unwrap();
        let details = ["seen on the pause screen".to_string()];
        retext(
            &v.p,
            &v.log,
            "scratch",
            &one,
            None,
            None,
            &details,
            false,
            None,
            Lane::Human,
            &Writer::of(None, None, None, None, &[], false, Vec::new()),
        )
        .unwrap();
        done(
            &v.p,
            &v.log,
            "scratch",
            &one,
            Some("pr:7"),
            None,
            None,
            Lane::Human,
        )
        .unwrap();
        let two = Pick::Id("sc-2".into());
        drop(
            &v.p,
            &v.log,
            "scratch",
            &two,
            Some("stale"),
            None,
            Lane::Human,
        )
        .unwrap();
        let ev = crate::ingest::all(&v.p);
        let got: Vec<(&str, Option<&str>, &str)> = ev
            .iter()
            .map(|e| (e.action.as_str(), e.id.as_deref(), e.lane.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("edited", Some("sc-1"), "human"),
                ("detailed", Some("sc-1"), "human"),
                ("done", Some("sc-1"), "human"),
                ("dropped", Some("sc-2"), "human"),
            ]
        );
        assert!(
            ev[0].text.contains("flickers"),
            "the old words: {:?}",
            ev[0]
        );
        assert!(
            ev[0].row.as_deref().is_some_and(|r| r.contains("blinks")),
            "the new words: {:?}",
            ev[0]
        );
        assert_eq!(ev[1].why.as_deref(), Some("seen on the pause screen"));
        assert_eq!(ev[2].why.as_deref(), Some("pr:7"));
        assert_eq!(ev[3].why.as_deref(), Some("dropped: stale"));
    }

    // A human-sheet row that rolled off its Done window reopens from the agent note's
    // `## Sheet done rows`, back onto the human sheet, and leaves the note.
    #[test]
    fn two_closes_with_the_same_bytes_both_reach_the_note() {
        let v = vault(
            "roll-twins",
            "",
            "- [ ] feat(ui): one #high <!-- id:sc-1 -->\n",
        );
        let sheet = v.root.join("projects/scratch/README.md");
        let note = v.root.join("projects/scratch/agent/versions/v0.1.0.md");
        let twin = "- [x] bump deps <!-- done:2026-10-01 -->";
        let content = fs::read_to_string(&sheet).unwrap() + &format!("{twin}\n{twin}\n");
        write_sheet(&sheet, &content).unwrap();
        let n = fs::read_to_string(&note).unwrap();
        assert_eq!(n.matches(twin).count(), 2, "{n}");
        assert!(!fs::read_to_string(&sheet).unwrap().contains("bump deps"));
        // the same row with an id, offered again, is written once
        let row = "- [x] fix(a): known <!-- id:sc-9 done:2026-10-01 -->";
        let content = fs::read_to_string(&sheet).unwrap() + row + "\n";
        write_sheet(&sheet, &content).unwrap();
        write_sheet(&sheet, &(fs::read_to_string(&sheet).unwrap() + row + "\n")).unwrap();
        assert_eq!(fs::read_to_string(&note).unwrap().matches(row).count(), 1);
    }

    #[test]
    fn only_a_sheet_or_board_path_is_swept() {
        for (path, sheet) in [
            ("lab/projects/current/demo/README.md", true),
            ("lab/projects/current/demo/agent/README.md", true),
            ("lab/projects/current/demo/tasks.md", true),
            ("lab/projects/current/demo/versions/v1.0.0.md", false),
            ("lab/projects/current/demo/versions/README.md", false),
            ("lab/projects/current/demo/docs/README.md", false),
            ("lab/projects/current/demo/ideas.md", false),
        ] {
            assert_eq!(is_sheet_path(Path::new(path)), sheet, "{path}");
        }
    }

    #[test]
    fn a_rolled_off_sheet_row_reopens_from_the_agent_note() {
        let v = vault(
            "reopen-rolled",
            "",
            "- [ ] feat(ui): one #high <!-- id:sc-1 -->\n",
        );
        let sheet = v.root.join("projects/scratch/README.md");
        let note = v.root.join("projects/scratch/agent/versions/v0.1.0.md");
        let one = Pick::Id("sc-1".into());
        done(
            &v.p,
            &v.log,
            "scratch",
            &one,
            Some("pr:7"),
            None,
            Some("2026-10-03"),
            Lane::Human,
        )
        .unwrap();
        let n = fs::read_to_string(&note).unwrap();
        assert!(
            n.contains(&format!("## {SHEET_DONE_ROWS}\n- [x] feat(ui): one")),
            "{n}"
        );
        assert!(!fs::read_to_string(&sheet).unwrap().contains("sc-1"));

        assert_eq!(
            reopen(&v.p, &v.log, "scratch", "sc-1", "wrong PR", Lane::Human).unwrap(),
            0
        );
        let s = fs::read_to_string(&sheet).unwrap();
        assert!(
            s.contains("- [ ] feat(ui): one #high <!-- id:sc-1 -->"),
            "{s}"
        );
        assert!(!fs::read_to_string(&note).unwrap().contains("sc-1"));
    }

    // NEGATIVE CONTROL: without `--on` the close carries today, which is what stamped the apply
    // day on every backfilled row; redate moves only a closed row's `done:` day.
    #[test]
    fn done_takes_the_close_day_and_redate_moves_a_closed_rows_day() {
        let v = vault(
            "redate",
            "",
            "- [ ] feat(ui): one #high <!-- id:sc-1 -->\n\
             - [ ] feat(ui): two, not done:2026-10-05 yet #high <!-- id:sc-2 -->\n",
        );
        let sheet = v.root.join("projects/scratch/README.md");
        let (one, two) = (Pick::Id("sc-1".into()), Pick::Id("sc-2".into()));
        let today = done_token(chrono::Local::now().date_naive());
        done(
            &v.p,
            &v.log,
            "scratch",
            &one,
            Some("pr:7"),
            None,
            Some("2026-10-03"),
            Lane::Human,
        )
        .unwrap();
        done(
            &v.p,
            &v.log,
            "scratch",
            &two,
            Some("pr:8"),
            None,
            None,
            Lane::Human,
        )
        .unwrap();
        // A close older than the Done window rolls off the sheet into the agent note.
        let note = v.root.join("projects/scratch/agent/versions/v0.1.0.md");
        let read = || {
            let s = fs::read_to_string(&sheet).unwrap();
            format!("{s}{}", fs::read_to_string(&note).unwrap_or_default())
        };
        let text = read();
        assert!(
            !fs::read_to_string(&sheet).unwrap().contains("sc-1"),
            "rolled off"
        );
        assert!(text.contains("id:sc-1 done:2026-10-03 pr:7"), "{text}");
        assert!(text.contains(&format!("id:sc-2 {today} pr:8")), "{text}");
        assert_eq!(
            redate(
                &v.p,
                &v.log,
                "scratch",
                "sc-2",
                "2026-10-05",
                false,
                Lane::Human
            )
            .unwrap(),
            0
        );
        let text = read();
        assert!(text.contains("id:sc-2 done:2026-10-05 pr:8"), "{text}");
        assert!(text.contains("two, not done:2026-10-05 yet"), "{text}");
        assert!(text.contains("id:sc-1 done:2026-10-03 pr:7"), "{text}");
        assert_eq!(
            redate(
                &v.p,
                &v.log,
                "scratch",
                "sc-9",
                "2026-10-05",
                false,
                Lane::Human
            )
            .unwrap(),
            1
        );
        assert!(redate(
            &v.p,
            &v.log,
            "scratch",
            "sc-2",
            "2999-01-01",
            false,
            Lane::Human
        )
        .is_err());
    }

    /// nc-1: a row aimed at a later release sits in `## Tasks` like any other, so `edit` and
    /// `drop` reach it by its exact line, its words or its id, and it keeps its release tag.
    /// Seen 2026-11-04, before `--migrate-rows` folded the old `## Wave` sections into
    /// `## Tasks`: an exact `edit` on a planned row said "no open task matches".
    #[test]
    fn edit_and_drop_reach_a_row_aimed_at_a_later_release() {
        let planned = "- [ ] fix(net): rotate the token #high #v0.2.0 <!-- id:sc-2 -->";
        assert!(
            sheet::is_later(planned, Some((0, 1, 0))),
            "the fixture's row is planned"
        );
        let v = vault(
            "planned",
            "",
            &format!("- [ ] fix(ui): the menu flickers #high <!-- id:sc-1 -->\n{planned}\n"),
        );
        let edited = |pick: Pick, text: Option<&str>, details: &[String]| {
            retext(
                &v.p,
                &v.log,
                "scratch",
                &pick,
                text,
                None,
                details,
                false,
                None,
                Lane::Human,
                &Writer::of(None, None, None, None, &[], false, Vec::new()),
            )
            .unwrap()
        };
        assert_eq!(
            edited(
                Pick::new(planned, true).unwrap(),
                Some("fix(net): rotate the host token"),
                &[]
            ),
            0
        );
        let row = "- [ ] fix(net): rotate the host token #high #v0.2.0 <!-- id:sc-2 -->";
        assert!(v.read().contains(row), "{}", v.read());
        assert_eq!(
            edited(
                Pick::new("host token", false).unwrap(),
                None,
                &["out of git".into()]
            ),
            0
        );
        assert!(
            v.read().contains(&format!("{row}\n  out of git\n")),
            "{}",
            v.read()
        );
        assert_eq!(
            drop(
                &v.p,
                &v.log,
                "scratch",
                &Pick::Id("sc-2".into()),
                Some("moot"),
                None,
                Lane::Human
            )
            .unwrap(),
            0
        );
        let sheet = v.read();
        let closed = sheet.lines().find(|l| l.contains("id:sc-2")).unwrap();
        assert!(
            closed.starts_with("- [x] fix(net): rotate the host token"),
            "{sheet}"
        );
        assert!(
            closed.contains("#v0.2.0") && closed.contains("dropped: moot"),
            "{sheet}"
        );
        assert!(
            sheet.contains("- [ ] fix(ui): the menu flickers"),
            "{sheet}"
        );
    }

    /// A vault with one project, `scratch`, whose sheet holds `inbox` and `tasks`.
    fn vault(tag: &str, inbox: &str, tasks: &str) -> Vault {
        let root = std::env::temp_dir().join(format!("notes-inbox-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dir = root.join("projects/scratch");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("summary.md"), "# scratch\n").unwrap();
        fs::write(
            dir.join("README.md"),
            format!("# scratch\nVersion: v0.1.0\n\n## Inbox\n{inbox}\n## Tasks\n{tasks}"),
        )
        .unwrap();
        let mut p = crate::config::test_profile(&root.to_string_lossy());
        p.projects = Some(root.join("projects"));
        let log = Logger::new(root.join(".state/log"), false);
        Vault { root, p, log }
    }

    fn rows(texts: &[&str]) -> Filing {
        Filing {
            project: None,
            lane: Lane::Human,
            want: None,
            why: None,
            how: How::Rows {
                texts: texts.iter().map(|t| t.to_string()).collect(),
                to: None,
                details: Vec::new(),
            },
        }
    }

    // A `#p1` survived on a sheet (2026-11-21): no edit writes a priority word no reader knows.
    // A row that already carries one still takes an edit, so it can be fixed or closed.
    #[test]
    fn an_edit_refuses_a_retired_priority_word() {
        let v = vault(
            "retired",
            "",
            "- [ ] fix(a): clean row #low <!-- id:sc-1 -->\n- [ ] fix(a): old row #p1 <!-- id:sc-2 -->\n",
        );
        let w = Writer::human();
        let id = |i: &str| Pick::Id(i.to_string());
        let tag_as = |pick: &Pick, t: &str| {
            tag(
                &v.p,
                &v.log,
                "scratch",
                pick,
                &[t.to_string()],
                &[],
                Lane::Human,
                &w,
            )
        };
        let before = v.read();
        let e = tag_as(&id("sc-1"), "p1").expect_err("refused").to_string();
        assert!(e.contains("#p1 is not a priority"), "{e}");
        let e = retext(
            &v.p,
            &v.log,
            "scratch",
            &id("sc-1"),
            Some("fix(a): clean row #medium"),
            None,
            &[],
            false,
            None,
            Lane::Human,
            &w,
        )
        .expect_err("refused")
        .to_string();
        assert!(e.contains("#medium is not a priority"), "{e}");
        let e = tag_as(&id("sc-2"), "p2").expect_err("refused").to_string();
        assert!(e.contains("#p2 is not a priority"), "{e}");
        // With a systems list the refusal comes before the standing epic is filed: a missing
        // systems binary would fail later, so this error proves nothing reached it.
        let e = retext(
            &v.p,
            &v.log,
            "scratch",
            &id("sc-1"),
            Some("fix(a): clean row #p3"),
            None,
            &[],
            false,
            Some("/nonexistent/systems"),
            Lane::Human,
            &w,
        )
        .expect_err("refused")
        .to_string();
        assert!(e.contains("#p3 is not a priority"), "{e}");
        assert_eq!(v.read(), before, "a refusal writes nothing");
        // NEGATIVE CONTROL: the row that already had #p1 still takes a tag.
        assert_eq!(tag_as(&id("sc-2"), "size/s").unwrap(), 0);
        assert!(v.read().contains("#size/s"));
        // #normal is a priority again (ar-4884): an edit writing it is accepted, and it
        // replaces the row's #low rather than joining it.
        assert_eq!(tag_as(&id("sc-1"), "normal").unwrap(), 0);
        let after = v.read();
        let row = after.lines().find(|l| l.contains("id:sc-1")).unwrap();
        assert!(row.contains("#normal") && !row.contains("#low"), "{row}");
    }

    #[test]
    fn a_raw_add_waits_in_the_inbox_and_a_typed_one_goes_to_tasks() {
        let v = vault("add", "", "");
        add(
            &v.p,
            &v.log,
            "scratch",
            "the gun sound is off",
            &[],
            None,
            None,
            Lane::Human,
            &Writer::human(),
        )
        .unwrap();
        add(
            &v.p,
            &v.log,
            "scratch",
            "fix(audio): gun sound",
            &[],
            None,
            None,
            Lane::Human,
            &Writer::human(),
        )
        .unwrap();
        let s = v.read();
        let inbox = s.split("## Tasks").next().unwrap();
        assert!(inbox.contains("- [ ] the gun sound is off\n"), "{s}");
        let tasks = s.split("## Tasks").nth(1).unwrap();
        assert!(tasks.contains("fix(audio): gun sound"), "{s}");
        assert!(!tasks.contains("the gun sound is off"), "{s}");
        assert!(
            inbox_flag(&v.p).is_file(),
            "the inbox write wakes the triager"
        );
    }

    #[test]
    fn the_parent_script_is_its_own_path_or_an_interpreters_first_word() {
        let argv = |s: &str| s.split(' ').map(str::to_string).collect::<Vec<_>>();
        let of = |s: &str| parent_script(&argv(s)).map(str::to_string);
        assert_eq!(
            of("/home/u/.local/bin/agent-ask post x").as_deref(),
            Some("agent-ask")
        );
        assert_eq!(
            of("bash /home/u/.local/bin/agent-queue add").as_deref(),
            Some("agent-queue")
        );
        assert_eq!(
            of("/usr/bin/python3.12 -I /x/research-pick").as_deref(),
            Some("research-pick")
        );
        assert_eq!(of("-zsh").as_deref(), None);
        // A string run by -c names no script, whatever words it holds.
        assert_eq!(of("/bin/zsh -c notes /x/agent-ask").as_deref(), None);
        assert_eq!(of("bash -c /x/agent-ask").as_deref(), None);
        assert_eq!(of("bash -lc /x/agent-ask").as_deref(), None);
        assert_eq!(of("perl -e /x/agent-ask").as_deref(), None);
        // A flag that takes a value does not name the script.
        assert_eq!(
            of("bash -o pipefail /x/agent-ask").as_deref(),
            Some("agent-ask")
        );
        assert_eq!(of("sh -e /x/agent-ask").as_deref(), Some("agent-ask"));
        assert_eq!(parent_script(&[]), None);
    }

    #[test]
    fn an_origin_counts_only_from_the_runner_or_the_script_it_names() {
        let s = |v: &str| Some(v.to_string());
        let argv = |a: &str| a.split(' ').map(str::to_string).collect::<Vec<_>>();
        let filers = || vec!["agent-ask".to_string(), "ask-sweep".to_string()];
        // A queue item `q`, a session `c`, a runner name: the environment's three words.
        let w = |q: Option<String>, run, o, parent: &str, plan| {
            Writer::of(q, s("c1"), run, o, &argv(parent), plan, filers())
        };
        let zsh = "/bin/zsh -c notes";
        // A queue item's claim alone files nothing and is named for the outbox note.
        let claimed = w(s("q1"), None, Some("agent-ask"), zsh, false);
        assert!(claimed.inboxes() && !claimed.self_checks());
        assert_eq!(claimed.refused.as_deref(), Some("agent-ask"));
        assert!(!w(s("q1"), None, Some("agent-ask"), "bash /b/agent-ask", false).inboxes());
        // A runner's own name, and an --origin that equals it.
        let runner = |run, o| Writer::of(None, None, run, o, &argv(zsh), false, filers());
        assert!(!runner(s("ask-sweep"), None).inboxes());
        assert!(!runner(s("ask-sweep"), Some("ask-sweep")).inboxes());
        // NEGATIVE CONTROL: a runner off the list, or a runner name a session inherited, inboxes.
        assert!(runner(s("some-runner"), None).inboxes());
        assert!(w(None, s("ask-sweep"), Some("ask-sweep"), zsh, false).inboxes());
        // `plan` is agent-queue filing a plan's row, and nothing else.
        assert!(!w(s("q1"), None, Some("plan"), "bash /b/agent-queue", true).inboxes());
        assert!(w(s("q1"), None, Some("plan"), "bash /b/agent-queue", false).inboxes());
        assert!(w(s("q1"), None, Some("plan"), "bash /b/agent-ask", true).inboxes());
        assert!(w(s("q1"), None, Some("plan"), zsh, true).inboxes());
        // A hand session (no queue item or runner) checks its own add, whatever --origin it
        // types; a filer the process vouches for files without the check.
        let hand = w(None, None, Some("plan"), zsh, true);
        assert!(!hand.inboxes() && hand.self_checks());
        assert!(!w(None, None, Some("agent-ask"), "bash /b/agent-ask", false).self_checks());
        // A person's terminal is no automated writer, whatever it passes.
        let person = |o| Writer::of(None, None, None, o, &argv(zsh), false, filers());
        assert!(!person(Some("anything")).inboxes() && !person(Some("anything")).self_checks());
        assert!(person(None).person);
    }

    #[test]
    fn a_frozen_window_takes_a_session_add_next_time_and_a_person_add_now() {
        let v = vault(
            "window",
            "",
            "- [ ] fix(a): committed row #urgent <!-- id:sc-1 -->\n",
        );
        let dir = v.root.join("projects/scratch");
        let sheet = dir.join("README.md");
        let s = fs::read_to_string(&sheet).unwrap();
        fs::write(
            &sheet,
            s.replace("Version: v0.1.0", "Version: v0.1.0 #prio/focus"),
        )
        .unwrap();
        let day = chrono::NaiveDate::from_ymd_opt(2026, 11, 18).unwrap();
        let ix = crate::epics::Index::of(&dir, Some((0, 1, 0)));
        let n = crate::window::record(&dir, "scratch", (0, 1, 0), day, None, &ix).unwrap();
        assert_eq!(n, Some(1));
        let session = Writer {
            automated: true,
            hand: false,
            checked: Vec::new(),
            person: false,
            name: Some("dispatch".into()),
            refused: None,
            filers: vec!["dispatch".into()],
        };
        // `from_env` with no session, runner or --origin: a person at a terminal.
        let person = Writer {
            automated: false,
            hand: false,
            checked: Vec::new(),
            person: true,
            name: None,
            refused: None,
            filers: Vec::new(),
        };
        let add_as = |text: &str, want: Option<&str>, w: &Writer| {
            add_via(
                &v.p,
                &v.log,
                "scratch",
                text,
                &[],
                None,
                want,
                Lane::Human,
                w,
                None,
            )
            .unwrap()
        };
        assert_eq!(add_as("fix(b): mid-window add", None, &session), 0);
        assert_eq!(add_as("fix(c): the human's ask", None, &person), 0);
        assert_eq!(add_as("fix(g): play build 12", None, &Writer::human()), 0);
        assert_eq!(add_as("fix(d): a red #interrupt", None, &session), 0);
        assert_eq!(add_as("fix(e): voice ask", Some("voice"), &session), 0);
        assert_eq!(add_as("fix(f): a follow-up", Some("outbox"), &session), 0);
        let s = v.read();
        let tags = |head: &str| {
            let row = s
                .lines()
                .find(|l| l.contains(head))
                .unwrap_or_else(|| panic!("{s}"));
            (row.contains("#interrupt"), row.contains("#v0.1.1"))
        };
        // NEGATIVE CONTROL: an agent add with no interrupt signal waits for the next window,
        // and so does an outbox follow-up.
        assert_eq!(tags("fix(b): mid-window add"), (false, true), "{s}");
        assert_eq!(tags("fix(f): a follow-up"), (false, true), "{s}");
        // and so does a command filing for itself, such as the playtest pass.
        assert_eq!(tags("fix(g): play build 12"), (false, true), "{s}");
        assert_eq!(tags("fix(c): the human's ask"), (true, false), "{s}");
        assert_eq!(tags("fix(d): a red"), (true, false), "{s}");
        assert_eq!(tags("fix(e): voice ask"), (true, false), "{s}");
        assert_eq!(tags("fix(a): committed row"), (false, false), "{s}");
    }

    #[test]
    fn only_a_person_moves_reprioritizes_or_relocks_an_open_sprints_rows() {
        let v = vault(
            "frozen",
            "",
            "- [ ] fix(a): committed row #urgent <!-- id:sc-1 -->\n\
             - [ ] fix(b): uncommitted row <!-- id:sc-2 -->\n",
        );
        let dir = v.root.join("projects/scratch");
        let s = fs::read_to_string(v.sheet()).unwrap();
        fs::write(
            v.sheet(),
            s.replace("Version: v0.1.0", "Version: v0.1.0 #prio/focus"),
        )
        .unwrap();
        let (open, next) = ((0, 1, 0), (0, 1, 1));
        let day = chrono::NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        let ix = crate::epics::Index::of(&dir, Some(open));
        assert_eq!(
            crate::window::record(&dir, "scratch", open, day, None, &ix).unwrap(),
            Some(1)
        );
        let argv = vec!["/bin/zsh".to_string()];
        let s = |v: &str| Some(v.to_string());
        let item = Writer::of(s("q1"), None, None, None, &argv, false, Vec::new());
        let hand = Writer::of(None, s("c1"), None, None, &argv, false, Vec::new());
        let person = Writer::of(None, None, None, None, &argv, false, Vec::new());
        let id = |i: &str| Pick::Id(i.to_string());
        let held = id("sc-1");
        let before = v.read();
        let refused = |r: Result<i32>| {
            let e = r.expect_err("refused").to_string();
            assert!(
                e.contains("open v0.1.0 sprint") && e.contains("terminal"),
                "{e}"
            );
        };
        let mv = |pick: &Pick, w: &Writer| {
            move_task(&v.p, &v.log, "scratch", pick, "v0.1.1", Lane::Human, w)
        };
        refused(mv(&held, &item));
        refused(mv(&held, &hand));
        refused(step(&v.p, &v.log, "scratch", &held, 1, Lane::Human, &item));
        let urgent = ["urgent".to_string()];
        let high = ["high".to_string()];
        refused(tag(
            &v.p,
            &v.log,
            "scratch",
            &held,
            &high,
            &urgent,
            Lane::Human,
            &hand,
        ));
        refused(tag(
            &v.p,
            &v.log,
            "scratch",
            &held,
            &[],
            &urgent,
            Lane::Human,
            &item,
        ));
        let words = |t: &str, w: &Writer| {
            let t = Some(t);
            retext(
                &v.p,
                &v.log,
                "scratch",
                &held,
                t,
                None,
                &[],
                false,
                None,
                Lane::Human,
                w,
            )
        };
        refused(words("fix(a): committed row #v0.1.1", &hand));
        assert_eq!(v.read(), before, "a refusal writes nothing");
        // New words that keep the priority and the version aim are an edit like any other.
        assert_eq!(words("fix(a): the committed row", &item).unwrap(), 0);
        // A tag that leaves the priority alone, and a row the window does not hold, pass.
        let size = ["size/s".to_string()];
        assert_eq!(
            tag(
                &v.p,
                &v.log,
                "scratch",
                &held,
                &size,
                &[],
                Lane::Human,
                &item
            )
            .unwrap(),
            0
        );
        assert_eq!(mv(&id("sc-2"), &item).unwrap(), 0);
        // A relock replaces a snapshot, so only a person takes one; an empty version queues.
        assert!(crate::window::refuse_relock(&dir, open, &item).is_err());
        assert!(crate::window::refuse_relock(&dir, open, &hand).is_err());
        assert!(crate::window::refuse_relock(&dir, open, &person).is_ok());
        assert!(crate::window::refuse_relock(&dir, next, &item).is_ok());
        // NEGATIVE CONTROL: the person moves the committed row.
        assert_eq!(mv(&held, &person).unwrap(), 0);
        let s = v.read();
        assert!(
            s.lines()
                .any(|l| l.contains("id:sc-1") && l.contains("#v0.1.1")),
            "{s}"
        );
    }

    #[test]
    fn filing_moves_the_line_to_a_typed_row_that_keeps_the_human_words() {
        let v = vault(
            "file",
            "- the gun sound is off\n  - since the top-down patch\n",
            "",
        );
        let pick = Pick::new("gun sound", false).unwrap();
        let rc = file(
            &v.p,
            &v.log,
            "scratch",
            &pick,
            &rows(&["fix(audio): gun sound #high"]),
            Lane::Human,
        )
        .unwrap();
        assert_eq!(rc, 0);
        let s = v.read();
        let (inbox, tasks) = s.split_once("## Tasks").unwrap();
        assert!(
            !inbox.contains("gun sound"),
            "the line left the inbox:\n{s}"
        );
        let row = tasks
            .lines()
            .find(|l| l.contains("fix(audio): gun sound"))
            .unwrap();
        assert!(row.contains("#high"), "{row}");
        let today = chrono::Local::now().date_naive();
        assert_eq!(
            filed_on(row),
            Some(today.format("%Y-%m-%d").to_string()),
            "{row}"
        );
        assert!(
            tasks.contains("  was: the gun sound is off\n  - since the top-down patch\n"),
            "{s}"
        );
        let ev = crate::ingest::on_day(&v.p, &today.format("%Y-%m-%d").to_string());
        assert_eq!(ev.len(), 1, "one filing, one record");
        assert_eq!(
            (
                ev[0].action.as_str(),
                ev[0].to.as_str(),
                ev[0].lane.as_str(),
                ev[0].text.as_str()
            ),
            ("filed", "scratch", "human", "the gun sound is off")
        );
        // the line is gone, so a second run finds nothing to file
        assert_eq!(
            file(
                &v.p,
                &v.log,
                "scratch",
                &pick,
                &rows(&["fix(audio): gun sound"]),
                Lane::Human
            )
            .unwrap(),
            1
        );
    }

    #[test]
    fn a_skipped_inbox_line_leaves_and_is_recorded_dropped_with_its_why() {
        let v = vault(
            "skip",
            "- a thought, not a task\n- keep this one\n",
            "- [ ] fix(ui): menu <!-- id:sc-4 -->\n",
        );
        let skip = Filing {
            project: None,
            lane: Lane::Human,
            want: None,
            why: Some("model: a note to self".into()),
            how: How::Skip,
        };
        let pick = Pick::new("a thought", false).unwrap();
        assert_eq!(
            file(&v.p, &v.log, "scratch", &pick, &skip, Lane::Human).unwrap(),
            0
        );
        let s = v.read();
        assert!(!s.contains("a thought"), "{s}");
        assert!(
            s.contains("- keep this one"),
            "only the named line leaves:\n{s}"
        );
        assert_eq!(
            s.matches("fix(ui): menu").count(),
            1,
            "no row was written:\n{s}"
        );
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let ev = crate::ingest::on_day(&v.p, &today);
        assert_eq!(ev.len(), 1, "one drop, one record");
        assert_eq!(
            (ev[0].action.as_str(), ev[0].why.as_deref()),
            ("dropped", Some("model: a note to self"))
        );
        // a line that is not there drops nothing (negative control)
        assert_eq!(
            file(&v.p, &v.log, "scratch", &pick, &skip, Lane::Human).unwrap(),
            1
        );
    }

    #[test]
    fn similar_ranks_open_rows_by_shared_title_words_and_skips_closed_and_unrelated_ones() {
        let board = "## Tasks\n\
- [ ] fix(ui): the pause menu flickers on resume <!-- id:sc-1 -->\n\
- [ ] fix(ui): the pause menu flickers on load screen <!-- id:sc-2 -->\n\
- [ ] feat(ui): the pause menu flickers on resume <!-- id:sc-3 -->\n\
- [ ] fix(audio): gun sound plays late <!-- id:sc-4 -->\n\
- [x] fix(ui): pause menu flickers on resume closed <!-- id:sc-5 -->\n";
        let hits = similar(
            board,
            "fix(ui): the pause menu flickers on resume #from/abc",
            10,
        );
        let ids: Vec<String> = hits.iter().map(|(_, l)| md::row_id(l).unwrap()).collect();
        // the same type(area) wins a tie; the audio row shares no word; the closed row is out
        assert_eq!(ids, ["sc-1", "sc-3", "sc-2"], "{hits:?}");
        assert_eq!(hits[0].0, 100);
        assert_eq!(
            similar(board, "fix(ui): pause menu flickers on resume", 2).len(),
            2
        );
        assert!(similar(board, "chore(x): zzz", 10).is_empty());
        // a row the writer refuses as a near-duplicate is one it ranks
        assert!(near_twin(board, "fix(ui): pause menu flickers on resume").is_some());
    }

    #[test]
    fn an_untyped_filing_and_a_dup_of_no_row_write_nothing() {
        let v = vault(
            "refuse",
            "- the gun sound is off\n",
            "- [ ] fix(ui): menu <!-- id:sc-4 -->\n",
        );
        let before = v.read();
        let pick = Pick::new("gun", false).unwrap();
        assert!(file(
            &v.p,
            &v.log,
            "scratch",
            &pick,
            &rows(&["gun sound"]),
            Lane::Human
        )
        .is_err());
        // a retired priority, and no --as on a line that is not typed yet
        for bad in [&["fix(audio): gun sound #medium"][..], &[]] {
            assert!(file(&v.p, &v.log, "scratch", &pick, &rows(bad), Lane::Human).is_err());
        }
        let dup = |id: &str| Filing {
            project: None,
            lane: Lane::Human,
            want: None,
            why: None,
            how: How::Dup(id.into()),
        };
        assert!(file(&v.p, &v.log, "scratch", &pick, &dup("sc-9"), Lane::Human).is_err());
        assert_eq!(v.read(), before);

        file(&v.p, &v.log, "scratch", &pick, &dup("sc-4"), Lane::Human).unwrap();
        let s = v.read();
        assert!(
            s.contains("- [ ] fix(ui): menu <!-- id:sc-4 -->\n  was: the gun sound is off\n"),
            "{s}"
        );
        assert!(!s.split("## Tasks").next().unwrap().contains("gun"), "{s}");
    }

    #[test]
    fn a_want_is_stamped_by_the_writer_and_its_channel_recorded() {
        let v = vault("want", "- the gun sound is off #agent\n", "");
        let agent = || {
            fs::read_to_string(task_sheet(&v.root.join("projects/scratch/agent")).unwrap()).unwrap()
        };
        let ingest = || fs::read_to_string(crate::ingest::path(&v.p)).unwrap_or_default();
        let add_as = |text: &str, want: Option<&str>| {
            add(
                &v.p,
                &v.log,
                "scratch",
                text,
                &[],
                None,
                want,
                Lane::Agent,
                &Writer::human(),
            )
        };
        // A bad channel writes nothing; no channel is no stamp.
        assert!(add_as("fix(audio): a #size/s", Some("shout")).is_err());
        add_as("fix(audio): b #size/s", None).unwrap();
        add_as("fix(audio): c #size/s", Some("voice")).unwrap();
        let s = agent();
        assert!(!s.contains("a #size"), "{s}");
        let row = |w: &str| s.lines().find(|l| l.contains(w)).unwrap().to_string();
        assert!(!row("audio): b").contains("#requested"), "{s}");
        assert!(row("audio): c").contains("#requested"), "{s}");
        assert!(ingest().contains(r#""want":"voice""#), "{}", ingest());
        assert!(!ingest().contains(r#""origin""#), "{}", ingest());
        // A named writer is recorded as the row's origin, so a reader tells a story row apart.
        let story = Writer {
            automated: false,
            hand: false,
            checked: Vec::new(),
            person: false,
            name: Some(crate::ingest::ORIGIN_STORY.into()),
            refused: None,
            filers: Vec::new(),
        };
        add(
            &v.p,
            &v.log,
            "scratch",
            "fix(audio): s #size/s",
            &[],
            None,
            None,
            Lane::Agent,
            &story,
        )
        .unwrap();
        let line = |w: &str| {
            ingest()
                .lines()
                .find(|l| l.contains(w))
                .unwrap()
                .to_string()
        };
        assert!(
            line("audio): s").contains(r#""origin":"agent-queue""#),
            "{}",
            ingest()
        );
        // File: the line's words stay as `was:`, each row is stamped, the channel is recorded.
        let pick = Pick::new("gun sound", false).unwrap();
        let mut how = rows(&["fix(audio): d #size/s", "fix(audio): e #size/s"]);
        how.want = Some("outbox");
        file(&v.p, &v.log, "scratch", &pick, &how, Lane::Human).unwrap();
        let s = agent();
        for w in ["audio): d", "audio): e"] {
            assert!(
                s.lines().any(|l| l.contains(w) && l.contains("#requested")),
                "{s}"
            );
        }
        assert!(s.contains("was: the gun sound is off"), "{s}");
        assert!(ingest().contains(r#""want":"outbox""#), "{}", ingest());
    }

    #[test]
    fn an_agent_tag_files_on_the_agent_board_without_the_tag() {
        let v = vault(
            "agenttag",
            "- [ ] chore(build): drop the old cache #agent #low\n- ci is slow on mac #agent\n",
            "",
        );
        let pick = Pick::new("old cache", false).unwrap();
        file(&v.p, &v.log, "scratch", &pick, &rows(&[]), Lane::Human).unwrap();
        let pick = Pick::new("ci is slow", false).unwrap();
        let as_rows = rows(&["perf(ci): the mac runs are slow #agent #size/s"]);
        file(&v.p, &v.log, "scratch", &pick, &as_rows, Lane::Human).unwrap();
        let human = v.read();
        assert!(
            !human.contains("old cache") && !human.contains("slow"),
            "{human}"
        );
        let agent = fs::read_to_string(task_sheet(&v.root.join("projects/scratch/agent")).unwrap())
            .unwrap();
        let row = |w: &str| agent.lines().find(|l| l.contains(w)).unwrap().to_string();
        assert!(
            row("old cache").starts_with("- [ ] chore(build): drop the old cache "),
            "{agent}"
        );
        assert!(
            row("mac runs").starts_with("- [ ] perf(ci): the mac runs are slow "),
            "{agent}"
        );
        assert!(agent.contains("was: ci is slow on mac #agent"), "{agent}");
        assert!(
            !row("old cache").contains("#agent") && !row("mac runs").contains("#agent"),
            "{agent}"
        );
    }

    #[test]
    fn a_typed_line_with_no_as_is_filed_as_written() {
        let v = vault(
            "asis",
            "- [ ] chore(build): drop the old cache #low
",
            "",
        );
        let pick = Pick::new("old cache", false).unwrap();
        file(&v.p, &v.log, "scratch", &pick, &rows(&[]), Lane::Human).unwrap();
        let s = v.read();
        let (inbox, tasks) = s.split_once("## Tasks").unwrap();
        assert!(!inbox.contains("old cache"), "{s}");
        let row = tasks.lines().find(|l| l.contains("old cache")).unwrap();
        assert!(
            row.starts_with("- [ ] chore(build): drop the old cache"),
            "{row}"
        );
        assert!(filed_on(row).is_some(), "{row}");
        assert!(!s.contains("was:"), "{s}");
    }

    #[test]
    fn a_was_rewrite_keeps_the_old_words_tags_and_stamps_and_refuses_untyped_or_unchanged_text() {
        let v = vault(
            "was",
            "",
            "- [ ] the menu flickers on resize #1469 #requested #tier/3 #size/m #high #c1026 <!-- id:sc-4 -->\n  - seen on the deck\n",
        );
        let before = v.read();
        let pick = Pick::new("sc-4", false).unwrap();
        let edit = |t: &str| {
            retext(
                &v.p,
                &v.log,
                "scratch",
                &pick,
                Some(t),
                None,
                &[],
                true,
                None,
                Lane::Human,
                &Writer::of(None, None, None, None, &[], false, Vec::new()),
            )
        };
        assert!(edit("make the menu stop flickering").is_err());
        assert_eq!(v.read(), before, "an untyped rewrite wrote nothing");
        assert_eq!(
            edit("fix(ui): the menu flickers on resize #size/s").unwrap(),
            0
        );
        let s = v.read();
        let row = s.lines().find(|l| l.contains("id:sc-4")).unwrap();
        assert!(
            row.starts_with(
                "- [ ] fix(ui): the menu flickers on resize #size/s #requested #tier/3"
            ),
            "{row}"
        );
        assert!(!row.contains("#size/m") && !row.contains("#1469"), "{row}");
        assert!(row.contains("#high") && row.contains("#c1026"), "{row}");
        assert!(
            s.contains("  - seen on the deck\n  was: the menu flickers on resize #1469 #requested #tier/3 #size/m\n"),
            "{s}"
        );

        // the same words again are no rewrite: no second was line
        assert_eq!(
            edit("fix(ui): the menu flickers on resize #size/m").unwrap(),
            0
        );
        assert_eq!(
            v.read(),
            s,
            "a rewrite to the row's own words wrote nothing"
        );
    }

    #[test]
    fn a_was_rewrite_over_80_chars_is_cut_at_a_word_with_the_whole_title_on_a_full_line() {
        let v = vault(
            "wasfull",
            "",
            "- [ ] the menu flickers #requested #size/m #c1026 <!-- id:sc-5 -->\n",
        );
        let pick = Pick::new("sc-5", false).unwrap();
        let title = format!(
            "{} {}",
            "word ".repeat(17).trim_end(),
            "tail ".repeat(5).trim_end()
        );
        assert!(title.chars().count() > projects::TITLE_MAX);
        let long = format!("fix(ui): {title} #size/s");
        let rc = retext(
            &v.p,
            &v.log,
            "scratch",
            &pick,
            Some(&long),
            None,
            &[],
            true,
            None,
            Lane::Human,
            &Writer::of(None, None, None, None, &[], false, Vec::new()),
        )
        .unwrap();
        assert_eq!(rc, 0);
        let s = v.read();
        let row = s.lines().find(|l| l.contains("id:sc-5")).unwrap();
        assert!(
            projects::row_title(row).chars().count() <= projects::TITLE_MAX,
            "{row}"
        );
        assert!(row.starts_with("- [ ] fix(ui): word word"), "{row}");
        assert!(
            row.contains("#size/s") && row.contains("#requested"),
            "{row}"
        );
        assert!(row.contains("#c1026") && !row.contains("tail"), "{row}");
        let was = s.find("  was: the menu flickers").expect("was line");
        let full = s.find(&format!("  full: {title}\n")).expect("full line");
        assert!(was < full, "{s}");
    }

    #[test]
    fn a_was_rewrite_title_with_no_space_in_80_chars_is_cut_hard() {
        let (t, full) = fit_title(&format!("fix(ui): {} #size/s", "x".repeat(100)));
        assert_eq!(t, format!("fix(ui): {} #size/s", "x".repeat(80)));
        assert_eq!(full.as_deref(), Some("x".repeat(100).as_str()));
    }

    #[test]
    fn a_was_rewrite_title_whose_80th_char_ends_a_word_keeps_that_word() {
        let title = format!("{} more", "x".repeat(80));
        let (t, _) = fit_title(&format!("fix(ui): {title}"));
        assert_eq!(t, format!("fix(ui): {}", "x".repeat(80)));
    }

    #[test]
    fn a_was_rewrite_title_that_fits_is_left_alone() {
        let (t, full) = fit_title("fix(ui): short title #size/s");
        assert_eq!(t, "fix(ui): short title #size/s");
        assert!(full.is_none());
    }

    #[test]
    fn start_and_unstart_leave_a_row_already_there_unchanged() {
        let v = vault("setonly", "", "- [ ] fix(ui): flicker <!-- id:sc-1 -->\n");
        let one = Pick::Id("sc-1".into());
        start(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        let once = v.read();
        assert!(once.contains("- [/] fix(ui): flicker"), "{once}");
        start(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        assert_eq!(v.read(), once, "a second start is a no-op, not an unstart");
        unstart(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        unstart(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        assert!(v.read().contains("- [ ] fix(ui): flicker"), "{}", v.read());
        let ev: Vec<String> = crate::ingest::all(&v.p)
            .into_iter()
            .map(|e| e.action)
            .collect();
        assert_eq!(ev, ["started", "unstarted"], "a no-op writes no event");
    }

    // The row records the queue: `run` marks the item started, `start` (a requeue), `unstart`
    // and `done` take the mark off again, and a second `run` writes nothing.
    #[test]
    fn run_marks_a_started_row_and_start_unstart_and_done_clear_it() {
        let v = vault("runmark", "", "- [ ] fix(ui): flicker <!-- id:sc-1 -->\n");
        let one = Pick::Id("sc-1".into());
        let today = chrono::Local::now().format("%m%d").to_string();
        run(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        let ran = v.read();
        assert!(
            ran.contains(&format!(
                "- [/] fix(ui): flicker <!-- id:sc-1 run:{today} -->"
            )),
            "{ran}"
        );
        assert!(ran.find("### Now") < ran.find("fix(ui): flicker"), "{ran}");
        run(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        assert_eq!(v.read(), ran, "a second run is a no-op");
        start(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        let queued = v.read();
        assert!(
            queued.contains("- [/] fix(ui): flicker <!-- id:sc-1 -->"),
            "{queued}"
        );
        assert!(
            queued.contains("### Next up") && !queued.contains("### Now"),
            "{queued}"
        );
        run(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        unstart(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        assert!(
            v.read().contains("- [ ] fix(ui): flicker <!-- id:sc-1 -->"),
            "{}",
            v.read()
        );
        run(&v.p, &v.log, "scratch", &one, Lane::Human).unwrap();
        assert_eq!(
            closed("- [/] a <!-- id:sc-1 run:1109 -->"),
            "- [x] a <!-- id:sc-1 -->"
        );
        assert_eq!(closed("- [/] a <!-- run:1109 -->"), "- [x] a");
    }

    // A row added with no priority stays untagged: it is untriaged, and a default would hide it.
    #[test]
    fn add_writes_no_default_priority() {
        let v = vault("addprio", "", "");
        for t in ["fix(ui): new thing", "fix(ui): hot #urgent"] {
            add(
                &v.p,
                &v.log,
                "scratch",
                t,
                &[],
                None,
                None,
                Lane::Human,
                &Writer::human(),
            )
            .unwrap();
        }
        let out = v.read();
        assert!(!out.contains("new thing #high"), "{out}");
        assert!(
            out.contains("fix(ui): hot") && out.contains("#urgent"),
            "{out}"
        );
    }

    // nc-47: words on two open rows act on neither; the error names both ids.
    #[test]
    fn ambiguous_words_are_refused_with_every_id() {
        let v = vault(
            "ambig",
            "",
            "- [ ] fix(ui): menu flicker <!-- id:sc-1 -->\n- [ ] fix(ui): menu lag <!-- id:sc-2 -->\n",
        );
        let err = Pick::new("menu", false)
            .unwrap()
            .resolve_in(&v.sheet())
            .unwrap_err()
            .to_string();
        assert!(err.contains("sc-1") && err.contains("sc-2"), "{err}");
        assert!(
            Pick::new("flicker", false)
                .unwrap()
                .resolve_in(&v.sheet())
                .is_ok(),
            "one hit is fine"
        );
        // A row whose whole words are the query is picked over a longer one containing them.
        let v = vault(
            "ambig2",
            "",
            "- [ ] fix(ui): menu\n- [ ] fix(ui): menu lag\n",
        );
        let pick = Pick::new("fix(ui): menu", false)
            .unwrap()
            .resolve_in(&v.sheet())
            .unwrap();
        assert_eq!(pick, Pick::Exact("- [ ] fix(ui): menu".into()));
    }
}
