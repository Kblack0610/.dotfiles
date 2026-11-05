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
use anyhow::{bail, Result};
use std::fs;
use std::path::{Path, PathBuf};

/// The version a directory's rows are read against: its own sheet's `Version:` line, else,
/// for an agent board (which carries none), the human sheet's one level up.
pub(crate) fn open_version_for(dir: &Path) -> Option<V> {
    let content = task_sheet(dir)
        .and_then(|s| fs::read_to_string(s).ok())
        .unwrap_or_default();
    version_in(dir, &content)
}

/// [`open_version_for`] for a caller already holding the sheet's text.
fn version_in(dir: &Path, content: &str) -> Option<V> {
    projects::sheet_version(content).or_else(|| {
        let parent = dir.parent().filter(|_| dir.ends_with("agent"))?;
        open_version_for(parent)
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
    pub rows: Vec<(usize, String)>,
    /// Lines waiting in the sheet's `## Inbox`.
    pub inbox: usize,
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
    let rows = sheet::current_rows(&content, cur)
        .into_iter()
        .map(|(n, l)| (n, l.trim_end().to_string()))
        .collect();
    Some(OpenRows {
        version: projects::version_or_default(cur),
        sheet: path,
        rows,
        inbox: sheet::inbox_lines(&content).len(),
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
            Pick::Exact(raw) => md::is_open_task(line) && line.trim_end() == raw,
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
/// The row is stamped as README "The task row" says: its created tag (`#cMMDD`), the default
/// priority when it has none, and its id (`<!-- id:<code>-<n> -->`, [`next_id`]) when the
/// registry gives the project a `code`. Each of `details` becomes an indented line under it.
///
/// On the human sheet, text with no `type(area): ` prefix is the human's own words, so it goes
/// to `## Inbox` as typed (plus the `--to` tag), unstamped, for the triager to file
/// ([`file`]). Nothing raw lands on the board. Agent-lane adds are typed by their writers.
pub fn add(
    p: &Profile,
    log: &Logger,
    name: &str,
    text: &str,
    details: &[String],
    to: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide task text)");
    }
    let proj_dir = projects::project_dir(p, name)?;
    let to = to.map(parse_to).transpose()?;
    let cur = open_version_for(&lane.dir(&proj_dir));
    if let Some(v) = to {
        refuse_behind(v, cur)?;
    }
    let path = ensure_lane_sheet(p, &proj_dir, name, lane)?;
    let content = fs::read_to_string(&path)?;
    if lane == Lane::Human && !is_typed(text) {
        let mut line = format!("- [ ] {text}");
        if let Some(v) = to {
            line = md::add_tag(&line, &projects::fmt_version(v));
        }
        let mut block = vec![line];
        block.extend(md::detail_lines("", details));
        let path = inbox_put(p, &proj_dir, name, &block)?;
        log.info("ptask", &format!("inboxed in {} ({name})", path.display()));
        crate::ingest::record(
            p,
            &crate::ingest::Event::row("added", name, "", lane.name(), &block[0]),
        );
        println!("inbox: {}", block.join("\n"));
        return Ok(0);
    }
    let block = new_rows(name, &proj_dir, &[text.to_string()], to, cur, &[], details)?;
    let new = md::insert_under_heading(&content, sheet::TASKS, &block);
    md::write_atomic(&path, &new)?;
    log.info("ptask", &format!("added to {} ({name})", path.display()));
    crate::ingest::record(
        p,
        &crate::ingest::Event::row("added", name, "", lane.name(), &block[0]),
    );
    for l in &block {
        println!("{l}");
    }
    Ok(0)
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
    md::write_atomic(&path, &sheet::put_in_inbox(&content, block))?;
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

/// Does `text` open with a well-formed `type(area): ` (README "The task row")?
fn is_typed(text: &str) -> bool {
    projects::row_type_area(&format!("- [ ] {text}")).is_some()
}

/// `new` plus each tag of `old` (`#requested`, `#tier/3`) whose name, the part before `/`, `new`
/// does not set: the row's own tags outlive a rewrite of its words. Issue and PR refs
/// (`#1469`) are words, not tags, so they stay in the `was:` line only.
fn carry_tags(old: &str, new: &str) -> String {
    let name = |t: &str| t.split('/').next().unwrap_or(t).to_string();
    let set: Vec<String> = md::find_hashtags(new).iter().map(|t| name(t)).collect();
    md::find_hashtags(old)
        .into_iter()
        .filter(|t| t.starts_with(|c: char| c.is_ascii_lowercase()) && !set.contains(&name(t)))
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
    let code = crate::registry::Registry::load().and_then(|r| r.code(name));
    if code.is_none() {
        eprintln!(
            "(no id: '{name}' has no `code` in project-map.json trackers; the row is unaddressable by id)"
        );
    }
    let first = code.as_ref().map(|c| next_id_n(proj_dir, c));
    let mut block = Vec::new();
    for (k, text) in texts.iter().enumerate() {
        let mut line = md::stamp_line(
            &md::with_default_priority(&format!("- [ ] {}", text.trim())),
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
        block.extend(md::detail_lines("", details));
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
                    "typed": is_typed(&l.text),
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
/// filed twice) and never on neither.
pub(crate) fn file(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    how: &Filing,
    lane: Lane,
) -> Result<i32> {
    let Some((src, content)) = sheet_and_content(p, name, lane)? else {
        bail!("'{name}' has no task sheet, so no inbox");
    };
    let Some((rest, line)) = sheet::take_inbox(&content, |l| inbox_hit(pick, l)) else {
        eprintln!("no inbox line matches '{pick}' in {name}");
        return Ok(1);
    };
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
            let texts: Vec<String> = if as_is {
                if !is_typed(&line.text) {
                    bail!("'{}' is not typed yet, so file needs --as \"<type(area): title>\" or --dup <id>", line.text);
                }
                vec![line.text.clone()]
            } else {
                texts.clone()
            };
            let texts: Vec<String> = texts.iter().map(|t| md::without_agent_tag(t)).collect();
            if let Some(bad) = texts.iter().find(|t| !is_typed(t)) {
                bail!("'{bad}' is not `type(area): title` (README \"The task row\"), so nothing was filed");
            }
            let to = to.as_deref().map(parse_to).transpose()?;
            let cur = version_in(&dest_dir, &base);
            if let Some(v) = to {
                refuse_behind(v, cur)?;
            }
            details.extend(extra.iter().cloned());
            let today = chrono::Local::now().date_naive();
            let block = new_rows(
                dest_name,
                &dest_proj,
                &texts,
                to,
                cur,
                &[filed_token(today)],
                &details,
            )?;
            if let Some(why) = projects::row_findings(&block.join("\n"), false).first() {
                bail!("{why}, so nothing was filed");
            }
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
    };
    md::write_atomic(&dest, &new_dest)?;
    if !same {
        md::write_atomic(&src, &rest).map_err(|e| {
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
    ev.id = match &how.how {
        How::Dup(id) => Some(id.clone()),
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

/// The next row id for a project: `<code>-<n>`, `n` one past the highest `id:<code>-N` on any
/// `.md` file under its dir (both lanes, playtest and `versions/`). A dropped row keeps its
/// id on the sheet and an archived one keeps it in `versions/`, so an id is never reused.
pub(crate) fn next_id(proj_dir: &Path, code: &str) -> String {
    format!("{code}-{}", next_id_n(proj_dir, code))
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
            } else if path.extension().is_some_and(|x| x == "md") {
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
) -> Result<i32> {
    let dir = lane_dir(p, name, lane)?;
    let Some(path) = task_sheet(&dir) else {
        bail!("'{name}' has no task sheet yet — add one with `notes ptask {name} add \"…\"`");
    };
    let content = fs::read_to_string(&path)?;
    let to = parse_to(to)?;
    let cur = version_in(&dir, &content);
    refuse_behind(to, cur)?;

    let Some((new, line)) = retarget(&content, pick, to, cur) else {
        eprintln!(
            "no open task matches '{pick}' outside {} in {name}",
            projects::fmt_version(to)
        );
        return Ok(1);
    };
    md::write_atomic(&path, &new)?;
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
/// already belong to `to`. Returns `(new_content, retagged_line)`, or `None` when nothing
/// outside the target matches, so a move onto its own version is a clear no-op.
fn retarget(content: &str, pick: &Pick, to: V, cur: Option<V>) -> Option<(String, String)> {
    let aim = |l: &str| project_sweep::retag(l.trim_end(), to, Some(to) == cur).0;
    let (new, matched) = md::edit_first_in_section(
        content,
        sheet::TASKS,
        |l| pick.hits(l) && sheet::version_of(l, cur) != Some(to),
        |l| Some(aim(l)),
    )?;
    Some((new, aim(&matched)))
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
pub fn move_to_project(
    p: &Profile,
    log: &Logger,
    src: &str,
    dest: &str,
    pick: &Pick,
    to: Option<&str>,
    lane: Lane,
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
    let Some(moved) = transfer(&src_sheet, &dest_sheet, pick, to)? else {
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
    Ok(0)
}

/// What a cross-project move did: both sheets' new text and the row as it landed.
#[derive(Debug)]
struct Lifted {
    src: String,
    dest: String,
    line: String,
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
    let Some(moved) = lift_into(&src, &dest, pick, to, dest_cur)? else {
        return Ok(None);
    };
    md::write_atomic(dest_sheet, &moved.dest)?;
    md::write_atomic(src_sheet, &moved.src).map_err(|e| {
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
/// project's roadmap, so it goes unless `to` names one. `None` on no match.
fn lift_into(
    src: &str,
    dest: &str,
    pick: &Pick,
    to: Option<V>,
    dest_cur: Option<V>,
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
    let mut landed = vec![line.clone()];
    landed.extend(block);
    let grown = md::insert_under_heading(dest, sheet::TASKS, &landed);
    Ok(Some(Lifted {
        src: cut,
        dest: grown,
        line,
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
) -> Result<i32> {
    let dir_word = if dir < 0 { "promote" } else { "demote" };
    let dir_proj = lane_dir(p, name, lane)?;
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

    let (retagged, note) = project_sweep::retag(&line, to, to == cur);
    let Some((new, _)) =
        md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), |_| Some(retagged))
    else {
        bail!("could not retag '{pick}'");
    };
    md::write_atomic(&path, &new)?;
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
pub fn done(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    proof: Option<&str>,
    unverified: Option<&str>,
    lane: Lane,
) -> Result<i32> {
    let stamp = proof_stamp(proof, unverified)?;
    let on = done_token(chrono::Local::now().date_naive());
    Ok(edit(p, log, name, pick, "done", Some(&stamp), lane, |l| {
        let ticked = md::add_marker(&md::set_checkbox(l, 'x'), &on);
        Some(md::add_marker(&ticked, &stamp))
    })?
    .0)
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
pub fn tag(
    p: &Profile,
    log: &Logger,
    name: &str,
    pick: &Pick,
    add: &[String],
    remove: &[String],
    lane: Lane,
) -> Result<i32> {
    let add: Vec<String> = add.iter().map(|t| tag_token(t)).collect::<Result<_>>()?;
    let remove: Vec<String> = remove.iter().map(|t| tag_token(t)).collect::<Result<_>>()?;
    if add.is_empty() && remove.is_empty() {
        bail!("tag needs --add <tag> or --remove <tag>");
    }
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
    Ok(format!("#{t}"))
}

/// `line` with `remove` dropped and `add` added. A row has one size, so adding a
/// `#size/<s>` replaces the size it had.
pub(crate) fn retag(line: &str, add: &[String], remove: &[String]) -> String {
    let sized = add.iter().any(|t| t.starts_with("#size/"));
    let old = size_tag(line).filter(|t| sized && !add.iter().any(|a| a == t));
    let l = old
        .into_iter()
        .chain(remove.iter().map(String::as_str))
        .fold(line.to_string(), |l, t| md::drop_tag(&l, t));
    add.iter().fold(l, |l, t| md::add_tag(&l, t))
}

/// The row's `#size/<s>` tag, read from its text before the marker comment.
pub(crate) fn size_tag(line: &str) -> Option<&str> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    head.split_whitespace().find(|w| w.starts_with("#size/"))
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
    Ok(
        edit(p, log, name, pick, "dropped", Some(&stamp), lane, |l| {
            Some(md::add_marker(&md::set_checkbox(l, 'x'), &stamp))
        })?
        .0,
    )
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

/// `notes ptask <name> edit <query> --text|--append` - change the first matching task's
/// text in place: replace it, or add `append` to the end of it. Its place on the sheet, its
/// checkbox state and its tags stay as they were ([`md::retext_task`]).
///
/// Each of `details` becomes an indented line at the end of the row's block, after its
/// existing detail lines and child rows. `--detail` alone leaves the row's own line as it is.
///
/// `was` is the triager's rewrite of an open row, the backlog twin of [`file`]: the new text
/// must be `type(area): title`, the old words go first among `details` as `was: <words>`, and
/// the old text's own tags (`#requested`, `#tier/3`, `#size/m`) carry over unless the new text
/// sets one of the same name ([`carry_tags`]).
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
    lane: Lane,
) -> Result<i32> {
    let (text, append) = (text.map(str::trim), append.map(str::trim));
    let rewrite;
    let mut with_was = Vec::new();
    let (text, details) = if was {
        let Some(t) = text.filter(|t| !t.is_empty()) else {
            bail!("--was rewrites a row, so it needs --text \"<type(area): title>\"");
        };
        if !is_typed(t) {
            bail!(
                "'{t}' is not `type(area): title` (README \"The task row\"), so nothing was edited"
            );
        }
        if projects::row_title(&format!("- [ ] {t}")).chars().count() > projects::TITLE_MAX {
            bail!(
                "'{t}': the title is over {} chars, so nothing was edited; the rest goes on a detail line",
                projects::TITLE_MAX
            );
        }
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
        with_was.extend(details.iter().cloned());
        (Some(rewrite.as_str()), &with_was[..])
    } else {
        (text, details)
    };
    let has_details = details.iter().any(|d| !d.trim().is_empty());
    if text.or(append).is_none_or(str::is_empty) && !has_details {
        bail!("edit needs the new words: --text \"<new text>\", --append \"<more>\" or --detail \"<line>\"");
    }
    if has_details {
        let Some((sheet, content)) = sheet_and_content(p, name, lane)? else {
            bail!("'{name}' has no task sheet yet");
        };
        let Some(new) = md::append_details(&content, sheet::TASKS, |l| pick.hits(l), details)
        else {
            eprintln!("no open task matches '{pick}' in {name}");
            return Ok(1);
        };
        md::write_atomic(&sheet, &new)?;
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
        if text.or(append).is_none_or(str::is_empty) {
            println!("detailed '{pick}'");
            return Ok(0);
        }
    }
    Ok(edit(p, log, name, pick, "edited", None, lane, |l| {
        let new = match (text, append) {
            (Some(t), _) => t.to_string(),
            (None, Some(a)) => format!("{} {a}", md::task_text(l)),
            (None, None) => unreachable!("checked above"),
        };
        Some(md::retext_task(l, &new))
    })?
    .0)
}

/// `notes ptask <name> start <query>` - toggle the first matching task between todo
/// (`[ ]`) and in-progress (`[/]`).
///
/// A row going to `[/]` with no id gets one, as [`add`] would have given it: a started row has
/// a queue item, and the item joins its row by that id, which survives a retext. The new id
/// goes on its own `  id:<id>` line after the usual output, so `fleet-dispatch` can read it.
pub fn start(p: &Profile, log: &Logger, name: &str, pick: &Pick, lane: Lane) -> Result<i32> {
    let dir = projects::project_dir(p, name)?;
    let id = crate::registry::Registry::load()
        .and_then(|r| r.code(name))
        .map(|code| next_id(&dir, &code));
    let (code, matched) = edit(p, log, name, pick, "toggled", None, lane, |l| {
        Some(toggle_started(l, id.as_deref()))
    })?;
    if let (Some(line), Some(id)) = (matched, id) {
        if md::row_id(&toggle_started(&line, Some(&id))).as_deref() == Some(id.as_str()) {
            println!("  id:{id}");
        }
    }
    Ok(code)
}

/// One row through `start`: `[/]` goes back to `[ ]` as it is; anything else goes to `[/]`,
/// stamped with `id` when it carries none.
fn toggle_started(line: &str, id: Option<&str>) -> String {
    if line.trim_start().starts_with("- [/]") {
        return md::set_checkbox(line, ' ');
    }
    let started = md::set_checkbox(line, '/');
    match id.filter(|_| md::row_id(line).is_none()) {
        Some(id) => md::add_marker(&started, &format!("id:{id}")),
        None => started,
    }
}

/// `notes ptask <name> sweep [--dry-run]` - reorganize the sheet's `## Tasks` section.
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
    let Some((new, report)) = project_sweep::sweep_sheet(&content) else {
        println!("{name}: already swept");
        return Ok(0);
    };
    for r in &report {
        println!("{r}");
    }
    if dry_run {
        println!("--dry-run: {} would change", sheet.display());
        return Ok(0);
    }
    md::write_atomic(&sheet, &new)?;
    log.info("ptask", &format!("swept {name}'s tasks"));
    let mut ev = crate::ingest::Event::new("swept", name, "", &report.join("; "));
    ev.lane = lane.name().into();
    crate::ingest::record(p, &ev);
    println!("{}", sheet.display());
    Ok(0)
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

/// Put `rows` at the end of the agent note's `## Done rows` section, adding the section
/// at the foot of the note when it has none.
fn append_done_rows(content: &str, rows: &[String]) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    match md::section_span(&lines, "Done rows") {
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
            out.push("## Done rows".to_string());
            out.extend(rows.iter().cloned());
        }
    }
    format!("{}\n", out.join("\n"))
}

/// `notes ptask <name> --agent archive [--dry-run]` - move the agent board's done rows into
/// `agent/versions/<vX.Y.Z>.md` (the human sheet's open version), under `## Done rows`, verbatim
/// and in board order, each with the proof stamp `done` put on it.
///
/// What keeps an agent board inside its budget (`notes doctor --projects`). The human
/// sheet has no archive: its done rows freeze with its version in `notes projects --release`.
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
    md::write_atomic(&board, &kept)?;
    log.info(
        "ptask",
        &format!("archived {n} done rows ({name}) -> {}", note.display()),
    );
    let mut ev = crate::ingest::Event::new("archived", name, "", &format!("{n} done rows"));
    ev.lane = lane.name().into();
    crate::ingest::record(p, &ev);
    println!("moved {n} done rows -> {}", note.display());
    Ok(0)
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
    let ver = projects::version_or_default(cur);
    let ver = ver.as_str();
    let lines: Vec<&str> = content.lines().collect();
    let rows: Vec<String> = ranges
        .iter()
        .flat_map(|r| lines[r.clone()].iter().map(|l| (*l).to_string()))
        .collect();
    let note = projects::ensure_agent_note(dir, name, ver)?;
    let prior = fs::read_to_string(&note)?;
    md::write_atomic(&note, &append_done_rows(&prior, &rows))?;
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
    Ok((format!("{}\n", kept.join("\n")), ranges.len()))
}

/// Shared body for `done`/`rm`/`start`: apply `f` to the first open task matching
/// `query`. Returns `(exit_code, matched_line)`. Non-zero exit on no-match (the cockpit
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
        let new = f(l);
        after.borrow_mut().clone_from(&new);
        new
    };
    match md::edit_first_in_section(&content, sheet::TASKS, |l| pick.hits(l), write) {
        Some((new, matched)) => {
            md::write_atomic(&sheet, &new)?;
            log.info("ptask", &format!("{verb} in {} ({name})", sheet.display()));
            let mut ev = crate::ingest::Event::row(verb, name, "", lane.name(), &matched);
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
        let (ver, open): (_, Vec<_>) = (w.version, w.rows.into_iter().map(|(_, l)| l).collect());
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
        let (ver, open): (_, Vec<_>) = (w.version, w.rows.into_iter().map(|(_, l)| l).collect());
        assert_eq!(ver, "v1.13.0");
        assert_eq!(open, vec!["- [ ] now"]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_move_retags_the_row_where_it_stands() {
        let pick = w("live one");
        let (new, line) = retarget(ROADMAP, &pick, (1, 15, 0), ROADMAP_CUR).unwrap();
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

    // `move --to` must retag, or the next `sweep` strips the row back to the open version.
    #[test]
    fn a_moved_row_takes_its_new_tag_and_survives_a_sweep() {
        let sheet =
            "# demo\nVersion: v1.13.0\n\n## Tasks\n- [ ] stays\n- [ ] moved #v1.13.0 #urgent\n";
        let (new, line) = retarget(sheet, &w("moved"), (1, 14, 0), ROADMAP_CUR).unwrap();
        assert!(
            line.contains("#v1.14.0") && !line.contains("#v1.13.0"),
            "{line}"
        );
        assert!(
            !line.contains("#urgent"),
            "urgent is only legal in the open version: {line}"
        );
        let swept = project_sweep::sweep_sheet(&new).map_or(new.clone(), |(c, _)| c);
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
        assert!(tag_token("v0.2.0")
            .unwrap_err()
            .to_string()
            .contains("move"));
        assert!(tag_token("two words").is_err());
        assert!(tag_token("#").is_err());
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
        lift_into(SRC, DEST, pick, to, Some((1, 2, 0)))
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
        let m = lift_into(&src, DEST, &w("spawn bug"), None, Some((1, 2, 0)))
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
        assert!(lift_into(SRC, prose, &w("spawn"), None, None).is_err());
    }

    #[test]
    fn a_cross_project_move_with_no_match_is_none() {
        assert!(lift(&w("no such row"), None).unwrap().is_none());
        // A closed row is not movable.
        let closed = SRC.replace("- [ ] dodgeball menu", "- [x] dodgeball menu");
        assert!(lift_into(&closed, DEST, &w("menu polish"), None, None)
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
    fn transfer_writes_both_sheets() {
        let d = scratch("ok");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let m = transfer(&s, &t, &w("spawn"), None).unwrap().unwrap();
        assert_eq!(fs::read_to_string(&s).unwrap(), m.src);
        assert_eq!(fs::read_to_string(&t).unwrap(), m.dest);
        assert!(!m.src.contains("spawn") && m.dest.contains("spawn"));
        let _ = fs::remove_dir_all(&d);
    }

    // Every refusal must leave both sheets byte-identical.
    #[test]
    fn transfer_refusals_write_nothing() {
        let d = scratch("refuse");
        let (s, t) = (d.join("src.md"), d.join("dest.md"));
        fs::write(&s, SRC).unwrap();
        fs::write(&t, DEST).unwrap();
        let same = transfer(&s, &s, &w("spawn"), None).unwrap_err().to_string();
        assert!(same.contains("same sheet"), "{same}");
        assert!(transfer(&s, &t, &w("spawn"), Some("next")).is_err());
        assert!(transfer(&s, &t, &w("no such row"), None).unwrap().is_none());
        assert_eq!(fs::read_to_string(&s).unwrap(), SRC);
        assert_eq!(fs::read_to_string(&t).unwrap(), DEST);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_same_project_move_keeps_the_row_in_place() {
        let (new, line) = retarget(SRC, &w("spawn"), (0, 5, 0), SRC_CUR).unwrap();
        assert_eq!(
            line,
            "- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->"
        );
        assert_eq!(
            new,
            "# unity-playground\nVersion: v0.4.0\n\n## Tasks\n- [ ] playground thing #high\n- [ ] dodgeball spawn bug #game #high #v0.5.0 <!-- since:2026-10-01 carried:2 -->\n- [ ] dodgeball menu polish #low\n- [ ] dodgeball netcode #v0.5.0 #high\n"
        );
    }

    #[test]
    fn start_toggles_todo_and_in_progress() {
        let (out, _) = md::edit_first_in_section(
            SHEET,
            sheet::TASKS,
            |l| is_match(l, "first"),
            |l| Some(toggle_started(l, None)),
        )
        .unwrap();
        assert!(out.contains("- [/] first task"));
    }

    // The join between a queue item and its row: the first start gives the row its id, and
    // neither a second start nor a row that already has one mints another.
    #[test]
    fn a_row_going_to_started_gets_its_id_once() {
        let line = toggle_started("- [ ] fix(a): thing #high", Some("ar-7"));
        assert_eq!(line, "- [/] fix(a): thing #high <!-- id:ar-7 -->");
        let back = toggle_started(&line, Some("ar-8"));
        assert_eq!(back, "- [ ] fix(a): thing #high <!-- id:ar-7 -->");
        assert_eq!(
            toggle_started(&back, Some("ar-8")),
            "- [/] fix(a): thing #high <!-- id:ar-7 -->"
        );
        assert_eq!(
            toggle_started("- [ ] a <!-- carried:1 -->", Some("ar-9")),
            "- [/] a <!-- carried:1 id:ar-9 -->"
        );
        // No code, no id: the row still starts, and the caller decides what that means.
        assert_eq!(toggle_started("- [ ] a", None), "- [/] a");
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
        let once = append_done_rows(note, &["- [x] one".to_string()]);
        assert!(
            once.ends_with("## Notes\n\n## Done rows\n- [x] one\n"),
            "{once}"
        );
        let twice = append_done_rows(&once, &["- [x] two".to_string()]);
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
        fs::write(dir.join("agent/README.md"), BOARD).unwrap();
        p.projects = Some(projects);
        p.project_index = Some(index);
        let log = Logger::new(root.join(".state/log"), false);

        assert!(archive(&p, &log, "demo", false, Lane::Human).is_err());
        archive(&p, &log, "demo", true, Lane::Agent).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("agent/README.md")).unwrap(),
            BOARD
        );

        archive(&p, &log, "demo", false, Lane::Agent).unwrap();
        let board = fs::read_to_string(dir.join("agent/README.md")).unwrap();
        assert_eq!(
            board,
            "# demo - agent board\nVersion: v0.0.1\n\n## Tasks\n- [ ] open row #high\n- [ ] open parent\n  - [x] a done subtask stays with its parent\n"
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

    /// A vault with one project, `scratch`, whose sheet holds `inbox` and `tasks`.
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
            Lane::Human,
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
            Lane::Human,
        )
        .unwrap();
        done(
            &v.p,
            &v.log,
            "scratch",
            &one,
            Some("pr:7"),
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
        let ev = crate::ingest::since(&v.p, 1);
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
            how: How::Rows {
                texts: texts.iter().map(|t| t.to_string()).collect(),
                to: None,
                details: Vec::new(),
            },
        }
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
            Lane::Human,
        )
        .unwrap();
        add(
            &v.p,
            &v.log,
            "scratch",
            "fix(audio): gun sound",
            &[],
            None,
            Lane::Human,
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
    fn a_was_rewrite_keeps_the_old_words_tags_and_stamps_and_refuses_untyped_long_or_unchanged_text(
    ) {
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
                Lane::Human,
            )
        };
        assert!(edit("make the menu stop flickering").is_err());
        assert_eq!(v.read(), before, "an untyped rewrite wrote nothing");
        let long = format!("fix(ui): {} #size/s", "x".repeat(81));
        assert!(edit(&long).is_err());
        assert_eq!(
            v.read(),
            before,
            "a rewrite with a title over 80 chars wrote nothing"
        );

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
}
