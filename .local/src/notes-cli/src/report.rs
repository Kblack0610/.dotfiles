//! `notes report add|list|read`: the one writer and reader of the reports agents file for the
//! human, plus the generated day index (`refs/<date>/_index.md`) that `link-refs` points the
//! daily note's `## Refs` at.
//!
//! A day's refs folder holds three kinds of file, told apart by a field, never a filename list:
//!   - a **report**: frontmatter `kind: report`, written only by [`add`];
//!   - a **digest**: frontmatter `generated: true` (the briefing, agents, shipped, infra-cleanup);
//!   - a **capture**: anything else, the human's own pastes and notes.
//!
//! Read and archived are states on a report, not file moves: `read:` is set by [`read`], and a
//! report is in the stream while it is today's or unread and under [`STREAM_DAYS`] old. Every
//! reader walks the folders live and never reads `_index.md`, so a hand paste shows up without a
//! rebuild. A day lives in `refs/<date>/`, or in the legacy `refs/archive/YYYY/YYYY-MM/<date>/`
//! the old monthly mover left; [`day_dir`] is the one resolver for both.

use crate::config::Profile;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, FixedOffset, Local, NaiveDate};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// The day index's file stem. Generated, never edited by hand.
pub const INDEX: &str = "_index";
/// Where the legacy monthly mover put old day folders, under the refs root.
const ARCHIVE: &str = "archive";
/// A summary is at most this many lines: it is what the index and the Reports tab show.
const MAX_SUMMARY_LINES: usize = 5;
/// An unread report stays in the stream this many days, then drops to the archive.
pub const STREAM_DAYS: i64 = 7;

#[derive(clap::Subcommand)]
pub enum Cmd {
    /// File a report (or revise one: the same slug on the same day updates it in place and
    /// marks it unread), then rebuild that day's index
    Add {
        #[arg(long)]
        title: String,
        /// 1-5 lines: what was found, what was done, what waits on the human
        #[arg(long)]
        summary: String,
        /// The report's body, a markdown file (`-` for stdin)
        #[arg(long)]
        body: String,
        /// The day the human reads it on (YYYY-MM-DD); default today
        #[arg(long)]
        date: Option<String>,
        /// The file name; default the title in kebab case. Pass the same one to revise
        #[arg(long)]
        slug: Option<String>,
        /// The report needs the human to act
        #[arg(long)]
        needs_you: bool,
        /// Who filed it: a queue item or session; default $AGENT_QUEUE_ITEM
        #[arg(long)]
        from: Option<String>,
    },
    /// The reports across days, newest first, read live from the folders
    List {
        /// One JSON object per line
        #[arg(long)]
        json: bool,
        /// Only days on or after this one (YYYY-MM-DD)
        #[arg(long)]
        since: Option<String>,
        /// Only reports not yet read
        #[arg(long)]
        unread: bool,
        /// Digests and captures too, each with its `kind`
        #[arg(long, conflicts_with = "unread")]
        all: bool,
    },
    /// Mark a report read by its id (`<date>-<slug>`)
    Read { id: String },
}

pub fn run(p: &Profile, log: &Logger, cmd: Cmd) -> Result<i32> {
    let now = Local::now().fixed_offset();
    match cmd {
        Cmd::Add {
            title,
            summary,
            body,
            date,
            slug,
            needs_you,
            from,
        } => {
            let body = if body == "-" {
                std::io::read_to_string(std::io::stdin())?
            } else {
                fs::read_to_string(&body).with_context(|| format!("reading {body}"))?
            };
            let day = match date {
                Some(d) => parse_day(&d)?,
                None => now.date_naive(),
            };
            let from = from
                .or_else(|| std::env::var("AGENT_QUEUE_ITEM").ok())
                .unwrap_or_default();
            let new = New {
                title,
                summary,
                body,
                day,
                slug,
                needs_you,
                from,
            };
            let (path, id) = add(p, log, &new, now)?;
            println!("{id}\t{}", path.display());
            Ok(0)
        }
        Cmd::List {
            json,
            since,
            unread,
            all,
        } => {
            let since = since.as_deref().map(parse_day).transpose()?;
            let rows = list(p, since, unread, all);
            for e in &rows {
                if json {
                    println!("{}", e.json(p, now.date_naive()));
                } else {
                    println!("{}", e.line());
                }
            }
            Ok(0)
        }
        Cmd::Read { id } => {
            let path = read(p, log, &id, now)?;
            println!("{}", path.display());
            Ok(0)
        }
    }
}

fn parse_day(s: &str) -> Result<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").with_context(|| format!("'{s}' is not YYYY-MM-DD"))
}

fn stamp(t: DateTime<FixedOffset>) -> String {
    t.format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

// ---- where a day lives ----

fn live_dir(p: &Profile, day: NaiveDate) -> PathBuf {
    p.refs.join(day.format("%Y-%m-%d").to_string())
}

fn archive_dir(p: &Profile, day: NaiveDate) -> PathBuf {
    p.refs
        .join(ARCHIVE)
        .join(day.format("%Y").to_string())
        .join(day.format("%Y-%m").to_string())
        .join(day.format("%Y-%m-%d").to_string())
}

/// The folder that holds `day`: `refs/<date>/`, else the legacy archive folder when only that
/// exists, else `refs/<date>/` (where a new write goes).
pub fn day_dir(p: &Profile, day: NaiveDate) -> PathBuf {
    let live = live_dir(p, day);
    let old = archive_dir(p, day);
    if !live.is_dir() && old.is_dir() {
        old
    } else {
        live
    }
}

/// A `[[refs/<date>/<rest>]]` wikilink target rewritten to the legacy archive folder of that
/// day, for the link resolver (`notes show`) when the live path does not exist. None for a
/// target outside refs or without a date.
pub fn archived_target(p: &Profile, target: &str) -> Option<String> {
    let rest = target
        .strip_prefix(p.refs_rel.as_str())?
        .strip_prefix('/')?;
    let (date, tail) = rest.split_once('/')?;
    let day = NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()?;
    Some(format!(
        "{}/{ARCHIVE}/{}/{}/{date}/{tail}",
        p.refs_rel,
        day.format("%Y"),
        day.format("%Y-%m")
    ))
}

/// Every day folder, live and archived, as `(day, dir)`, oldest first. A day in both places
/// lists both: the archive half first.
fn days(p: &Profile) -> Vec<(NaiveDate, PathBuf)> {
    fn dated(dir: &Path) -> Vec<(NaiveDate, PathBuf)> {
        fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_dir())
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                Some((NaiveDate::parse_from_str(&name, "%Y-%m-%d").ok()?, e.path()))
            })
            .collect()
    }
    let mut out = Vec::new();
    for year in dated_names(&p.refs.join(ARCHIVE)) {
        for month in dated_names(&year) {
            out.extend(dated(&month));
        }
    }
    out.extend(dated(&p.refs));
    out.sort_by_key(|(d, _)| *d);
    out
}

/// The subfolders of `dir`, any name (the archive's `YYYY` and `YYYY-MM` levels).
fn dated_names(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}

// ---- the contract ----

/// `---`-fenced frontmatter at the top of `content`: `key: value` lines, a `"..."` value
/// unquoted as JSON (the writer quotes with JSON, which YAML reads too), and a `key: |-` block
/// taking the indented lines under it. None when there is no frontmatter.
fn frontmatter(content: &str) -> Option<BTreeMap<String, String>> {
    let rest = content.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    let mut out = BTreeMap::new();
    let mut lines = rest[..end].lines().peekable();
    while let Some(line) = lines.next() {
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        if k.is_empty() || k.starts_with(' ') {
            continue;
        }
        let v = v.trim();
        let value = if v == "|-" || v == "|" {
            let mut block = Vec::new();
            while let Some(next) = lines.peek() {
                match next.strip_prefix("  ") {
                    Some(text) => block.push(text.to_string()),
                    None if next.trim().is_empty() => block.push(String::new()),
                    None => break,
                }
                lines.next();
            }
            block.join("\n").trim_end().to_string()
        } else if v.starts_with('"') {
            serde_json::from_str::<String>(v).unwrap_or_else(|_| v.to_string())
        } else {
            v.to_string()
        };
        out.insert(k.trim().to_string(), value);
    }
    Some(out)
}

/// The text after the frontmatter (all of `content` when it has none).
pub(crate) fn body_of(content: &str) -> &str {
    content
        .strip_prefix("---\n")
        .and_then(|rest| {
            let end = rest.find("\n---")?;
            let after = &rest[end + 4..];
            Some(after.strip_prefix('\n').unwrap_or(after))
        })
        .unwrap_or(content)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Report,
    Digest,
    Capture,
}

impl Kind {
    fn word(self) -> &'static str {
        match self {
            Kind::Report => "report",
            Kind::Digest => "digest",
            Kind::Capture => "capture",
        }
    }
}

/// One file in a day folder, read from its frontmatter.
#[derive(Debug, Clone)]
pub struct Entry {
    pub kind: Kind,
    pub day: NaiveDate,
    pub stem: String,
    pub path: PathBuf,
    pub title: String,
    pub summary: String,
    pub from: String,
    pub needs_you: bool,
    pub created: String,
    pub updated: String,
    pub read: String,
}

impl Entry {
    fn id(&self) -> String {
        format!("{}-{}", self.day.format("%Y-%m-%d"), self.stem)
    }

    fn unread(&self) -> bool {
        self.kind == Kind::Report && self.read.is_empty()
    }

    /// In the stream: today's, or an unread report under [`STREAM_DAYS`] old. Everything else
    /// is the archive.
    fn stream(&self, today: NaiveDate) -> bool {
        self.day == today
            || (self.unread() && (today - self.day).num_days() < STREAM_DAYS && self.day <= today)
    }

    /// The wikilink target: the refs-relative path, so an archived day links where it is.
    fn target(&self, p: &Profile) -> String {
        let rel = self.path.strip_prefix(&p.refs).unwrap_or(&self.path);
        let rel = rel.to_string_lossy();
        format!("{}/{}", p.refs_rel, rel.strip_suffix(".md").unwrap_or(&rel))
    }

    fn json(&self, p: &Profile, today: NaiveDate) -> Value {
        json!({
            "id": self.id(),
            "kind": self.kind.word(),
            "date": self.day.format("%Y-%m-%d").to_string(),
            "slug": self.stem,
            "title": self.title,
            "summary": self.summary,
            "from": self.from,
            "needs_you": self.needs_you,
            "created": self.created,
            "updated": self.updated,
            "read": (!self.read.is_empty()).then_some(&self.read),
            "stream": self.stream(today),
            "target": self.target(p),
            "path": self.path.display().to_string(),
        })
    }

    fn line(&self) -> String {
        let state = match (self.kind, self.needs_you, self.read.is_empty()) {
            (Kind::Report, true, true) => "needs you",
            (Kind::Report, _, true) => "unread",
            (Kind::Report, _, false) => "read",
            (k, _, _) => k.word(),
        };
        format!("{}  {:<9}  {}  {}", self.day, state, self.id(), self.title)
    }

    /// The summary's first line, for the index.
    fn lead(&self) -> &str {
        self.summary.lines().next().unwrap_or("").trim()
    }
}

fn mtime(path: &Path) -> String {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .map(|t| stamp(DateTime::<Local>::from(t).fixed_offset()))
        .unwrap_or_default()
}

/// The entry for `path` in `day`'s folder, classed by its frontmatter.
fn entry(day: NaiveDate, path: &Path) -> Option<Entry> {
    let stem = path.file_stem()?.to_str()?.to_string();
    let content = fs::read_to_string(path).ok()?;
    let fm = frontmatter(&content).unwrap_or_default();
    let get = |k: &str| fm.get(k).cloned().unwrap_or_default();
    let kind = if get("kind") == "report" {
        Kind::Report
    } else if get("generated") == "true" {
        Kind::Digest
    } else {
        Kind::Capture
    };
    let heading = || {
        body_of(&content)
            .lines()
            .find_map(|l| l.strip_prefix("# "))
            .map(|t| t.trim().to_string())
    };
    Some(if kind == Kind::Report {
        Entry {
            kind,
            day,
            stem: stem.clone(),
            path: path.to_path_buf(),
            title: Some(get("title"))
                .filter(|t| !t.is_empty())
                .or_else(heading)
                .unwrap_or(stem),
            summary: get("summary"),
            from: get("from"),
            needs_you: get("needs_you") == "true",
            created: get("created"),
            updated: get("updated"),
            read: get("read"),
        }
    } else {
        let at = mtime(path);
        Entry {
            kind,
            day,
            title: heading().unwrap_or_else(|| stem.clone()),
            stem,
            path: path.to_path_buf(),
            summary: String::new(),
            from: String::new(),
            needs_you: false,
            created: at.clone(),
            updated: at,
            read: String::new(),
        }
    })
}

/// Every file in `dir` but the index, as entries of `day`, sorted by stem.
pub fn entries(day: NaiveDate, dir: &Path) -> Vec<Entry> {
    let mut out: Vec<Entry> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("md"))
        .filter(|p| p.file_stem().and_then(|s| s.to_str()) != Some(INDEX))
        .filter_map(|p| entry(day, &p))
        .collect();
    out.sort_by(|a, b| a.stem.cmp(&b.stem));
    out
}

// ---- the index ----

/// A wikilink label: no character that ends or splits the link.
fn label(s: &str) -> String {
    s.replace('|', "/").replace(['[', ']'], "")
}

/// `day`'s `_index.md` text, built from its entries: Needs you (unread reports that need the
/// human), Reports (title and the summary's first line, newest first), Digests, Your notes.
pub fn index_text(p: &Profile, day: NaiveDate, all: &[Entry]) -> String {
    let link = |e: &Entry| format!("[[{}|{}]]", e.target(p), label(&e.title));
    let mut reports: Vec<&Entry> = all.iter().filter(|e| e.kind == Kind::Report).collect();
    reports.sort_by(|a, b| b.created.cmp(&a.created));
    let (needs, rest): (Vec<&Entry>, Vec<&Entry>) =
        reports.into_iter().partition(|e| e.needs_you && e.unread());
    let report_line = |e: &&Entry| match e.lead() {
        "" => format!("- {}", link(e)),
        lead => format!("- {}: {lead}", link(e)),
    };
    let mut s = format!(
        "---\ngenerated: true\ntags: [refs]\n---\n\n# Refs {}\n\nBuilt by `notes report` and `notes link-refs` from this folder; edits here are overwritten.\n",
        day.format("%Y-%m-%d")
    );
    let mut section = |heading: &str, lines: Vec<String>| {
        if !lines.is_empty() {
            s.push_str(&format!("\n## {heading}\n\n{}\n", lines.join("\n")));
        }
    };
    section("Needs you", needs.iter().map(report_line).collect());
    section("Reports", rest.iter().map(report_line).collect());
    for (heading, kind) in [("Digests", Kind::Digest), ("Your notes", Kind::Capture)] {
        section(
            heading,
            all.iter()
                .filter(|e| e.kind == kind)
                .map(|e| format!("- {}", link(e)))
                .collect(),
        );
    }
    if all.is_empty() {
        s.push_str("\nNothing filed yet.\n");
    }
    s
}

fn lock(p: &Profile) -> Result<md::FileLock> {
    md::lock_file(&p.state_dir.join("report.lock"))
}

/// Rebuild `day`'s `_index.md` when its folder exists, writing only on a change, and return the
/// day's entries (empty when there is no folder).
pub fn rebuild_index(p: &Profile, day: NaiveDate) -> Result<Vec<Entry>> {
    let dir = day_dir(p, day);
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let _lock = lock(p)?;
    let all = entries(day, &dir);
    let text = index_text(p, day, &all);
    let path = dir.join(format!("{INDEX}.md"));
    if fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
        md::write_atomic(&path, &text)?;
    }
    Ok(all)
}

// ---- add ----

pub struct New {
    pub title: String,
    pub summary: String,
    pub body: String,
    pub day: NaiveDate,
    pub slug: Option<String>,
    pub needs_you: bool,
    pub from: String,
}

/// `title` in kebab case: lowercase letters and digits, every other run one `-`, at most 60.
fn slugify(title: &str) -> String {
    let mut s = String::new();
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c.to_ascii_lowercase());
        } else if !s.ends_with('-') && !s.is_empty() {
            s.push('-');
        }
    }
    let s = s.trim_end_matches('-');
    let mut cut = s.chars().take(60).collect::<String>();
    while cut.ends_with('-') {
        cut.pop();
    }
    cut
}

fn valid_slug(s: &str) -> bool {
    !s.is_empty()
        && s.split('-').all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
}

/// Refuse non-ASCII text: names the field, line and character.
fn ascii(field: &str, text: &str) -> Result<()> {
    for (i, line) in text.lines().enumerate() {
        if let Some(c) = line.chars().find(|c| !c.is_ascii()) {
            bail!(
                "{field} line {} has non-ASCII {c:?} (U+{:04X}): reports are plain ASCII",
                i + 1,
                c as u32
            );
        }
    }
    Ok(())
}

/// The summary's lines, checked: 1 to [`MAX_SUMMARY_LINES`] non-blank lines.
fn summary_lines(summary: &str) -> Result<Vec<String>> {
    let lines: Vec<String> = summary
        .lines()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.trim().is_empty())
        .collect();
    if lines.is_empty() {
        bail!("a report needs a --summary (1-{MAX_SUMMARY_LINES} lines)");
    }
    if lines.len() > MAX_SUMMARY_LINES {
        bail!(
            "the summary is {} lines; at most {MAX_SUMMARY_LINES} (the detail goes in --body)",
            lines.len()
        );
    }
    Ok(lines)
}

fn quote(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_default()
}

/// A report file: the contract's frontmatter, then `# title`, then the body.
fn render(e: &Entry, body: &str) -> String {
    let mut s = String::from("---\nkind: report\n");
    s.push_str(&format!("id: {}\n", e.id()));
    s.push_str(&format!("title: {}\n", quote(&e.title)));
    s.push_str("summary: |-\n");
    for l in e.summary.lines() {
        s.push_str(&format!("  {l}\n"));
    }
    s.push_str(&format!("from: {}\n", quote(&e.from)));
    s.push_str(&format!("needs_you: {}\n", e.needs_you));
    s.push_str(&format!("created: {}\n", e.created));
    s.push_str(&format!("updated: {}\n", e.updated));
    s.push_str(&format!("read: {}\n", quote(&e.read)));
    s.push_str(&format!("---\n\n# {}\n\n", e.title));
    let body = body.trim();
    if !body.is_empty() {
        s.push_str(body);
        s.push('\n');
    }
    s
}

/// The body without a leading `# heading` (the title is written from `--title`). A body with
/// frontmatter of its own is refused, since the fields come from the flags.
fn clean_body(body: &str) -> Result<String> {
    if body.starts_with("---\n") {
        bail!("the body has frontmatter of its own; pass its fields as flags and drop it");
    }
    let trimmed = body.trim_start();
    let rest = match trimmed.lines().next() {
        Some(first) if first.starts_with("# ") => &trimmed[first.len()..],
        _ => trimmed,
    };
    Ok(rest.trim().to_string())
}

/// File (or revise) a report, then rebuild its day's index and link it from that day's note.
/// Returns the file and the id.
pub fn add(
    p: &Profile,
    log: &Logger,
    new: &New,
    now: DateTime<FixedOffset>,
) -> Result<(PathBuf, String)> {
    let title = new.title.trim();
    if title.is_empty() || title.contains('\n') {
        bail!("a report needs a one-line --title");
    }
    ascii("the title", title)?;
    ascii("the summary", &new.summary)?;
    ascii("the body", &new.body)?;
    ascii("--from", &new.from)?;
    let summary = summary_lines(&new.summary)?.join("\n");
    let body = clean_body(&new.body)?;
    let slug = match &new.slug {
        Some(s) if valid_slug(s) && s != INDEX => s.clone(),
        Some(s) => bail!("'{s}' is not a slug (lowercase words joined by -)"),
        None => slugify(title),
    };
    if slug.is_empty() {
        bail!("the title has no letters or digits to make a slug from; pass --slug");
    }
    let dir = day_dir(p, new.day);
    let path = dir.join(format!("{slug}.md"));
    {
        let _lock = lock(p)?;
        let at = stamp(now);
        let created = match fs::read_to_string(&path) {
            Ok(old) => {
                let fm = frontmatter(&old).unwrap_or_default();
                if fm.get("kind").map(String::as_str) != Some("report") {
                    bail!(
                        "{} exists and is not a report; pick another --slug",
                        path.display()
                    );
                }
                fm.get("created").cloned().unwrap_or_else(|| at.clone())
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => at.clone(),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        let e = Entry {
            kind: Kind::Report,
            day: new.day,
            stem: slug.clone(),
            path: path.clone(),
            title: title.to_string(),
            summary,
            from: new.from.trim().to_string(),
            needs_you: new.needs_you,
            created,
            updated: at,
            read: String::new(),
        };
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        md::write_atomic(&path, &render(&e, &body))?;
    }
    crate::daily::link_day_refs(p, log, new.day)?;
    let id = format!("{}-{slug}", new.day.format("%Y-%m-%d"));
    log.info("report", &format!("filed {id}"));
    Ok((path, id))
}

// ---- list and read ----

/// Reports across every day folder, newest day first and newest first within a day. `since`
/// keeps days on or after it, `unread` only unread reports, `all` adds digests and captures.
pub fn list(p: &Profile, since: Option<NaiveDate>, unread: bool, all: bool) -> Vec<Entry> {
    let mut out: Vec<Entry> = days(p)
        .into_iter()
        .filter(|(d, _)| since.is_none_or(|s| *d >= s))
        .flat_map(|(d, dir)| entries(d, &dir))
        .filter(|e| all || e.kind == Kind::Report)
        .filter(|e| !unread || e.unread())
        .collect();
    out.sort_by(|a, b| b.day.cmp(&a.day).then_with(|| b.created.cmp(&a.created)));
    out
}

/// The report an id (`<date>-<slug>`) names.
fn find(p: &Profile, id: &str) -> Result<Entry> {
    let (date, slug) = (id.get(..10), id.get(11..));
    let (Some(date), Some(slug)) = (date, slug) else {
        bail!("'{id}' is not a report id (<date>-<slug>)");
    };
    let day = parse_day(date)?;
    if !valid_slug(slug) || id.as_bytes()[10] != b'-' {
        bail!("'{id}' is not a report id (<date>-<slug>)");
    }
    let path = day_dir(p, day).join(format!("{slug}.md"));
    match entry(day, &path) {
        Some(e) if e.kind == Kind::Report => Ok(e),
        Some(_) => bail!("{} is not a report", path.display()),
        None => bail!("no report {id}"),
    }
}

/// Mark the report `id` read (kept as first read when it already is), then rebuild its day's
/// index. Returns its file.
pub fn read(p: &Profile, log: &Logger, id: &str, now: DateTime<FixedOffset>) -> Result<PathBuf> {
    let e = find(p, id)?;
    if e.read.is_empty() {
        let _lock = lock(p)?;
        let content = fs::read_to_string(&e.path)?;
        let marked = content.replacen(
            "\nread: \"\"\n",
            &format!("\nread: {}\n", quote(&stamp(now))),
            1,
        );
        if marked == content {
            bail!("{} has no empty read: field to set", e.path.display());
        }
        md::write_atomic(&e.path, &marked)?;
        log.info("report", &format!("read {id}"));
    }
    rebuild_index(p, e.day)?;
    Ok(e.path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn at(s: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(s).unwrap()
    }

    fn vault(name: &str) -> (PathBuf, Profile, Logger) {
        let dir = std::env::temp_dir().join(format!("notes-report-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("journal/daily")).unwrap();
        let mut p = crate::config::test_profile(dir.to_str().unwrap());
        p.state_dir = dir.join("state");
        let log = Logger::new(dir.join("log"), false);
        (dir, p, log)
    }

    fn new(title: &str, summary: &str, day: &str) -> New {
        New {
            title: title.into(),
            summary: summary.into(),
            body: "Detail line.\n".into(),
            day: d(day),
            slug: None,
            needs_you: false,
            from: "item-1".into(),
        }
    }

    /// Add writes the contract, list reads it back, read marks it, and a second add of the same
    /// slug is a revision: same file, created kept, updated moved, read cleared.
    #[test]
    fn add_list_read_and_a_same_slug_revision() {
        let (dir, p, log) = vault("cycle");
        let mut n = new(
            "Nightly flake readout",
            "4 flaky specs\n2 quarantined",
            "2026-11-24",
        );
        n.body = "# Old heading\n\nThe table.\n".into();
        let (path, id) = add(&p, &log, &n, at("2026-11-24T07:02:00-08:00")).unwrap();
        assert_eq!(id, "2026-11-24-nightly-flake-readout");
        assert_eq!(
            path,
            dir.join("journal/refs/2026-11-24/nightly-flake-readout.md")
        );
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("---\nkind: report\nid: 2026-11-24-nightly-flake-readout\ntitle: \"Nightly flake readout\"\nsummary: |-\n  4 flaky specs\n  2 quarantined\nfrom: \"item-1\"\nneeds_you: false\ncreated: 2026-11-24T07:02:00-08:00\nupdated: 2026-11-24T07:02:00-08:00\nread: \"\"\n---\n\n# Nightly flake readout\n\nThe table.\n"), "{text}");

        let rows = list(&p, None, false, false);
        assert_eq!(rows.len(), 1);
        let j = rows[0].json(&p, d("2026-11-24"));
        assert_eq!(j["summary"], "4 flaky specs\n2 quarantined");
        assert_eq!(j["read"], Value::Null);
        assert_eq!(j["stream"], true);
        assert_eq!(j["target"], "journal/refs/2026-11-24/nightly-flake-readout");
        assert_eq!(list(&p, None, true, false).len(), 1);

        read(&p, &log, &id, at("2026-11-24T09:00:00-08:00")).unwrap();
        let rows = list(&p, None, false, false);
        assert_eq!(rows[0].read, "2026-11-24T09:00:00-08:00");
        assert!(list(&p, None, true, false).is_empty());

        n.summary = "5 flaky specs".into();
        add(&p, &log, &n, at("2026-11-24T10:00:00-08:00")).unwrap();
        let rows = list(&p, None, false, false);
        assert_eq!(rows.len(), 1, "a revision, not a duplicate");
        assert_eq!(rows[0].created, "2026-11-24T07:02:00-08:00");
        assert_eq!(rows[0].updated, "2026-11-24T10:00:00-08:00");
        assert_eq!(rows[0].read, "", "a revision is unread again");
        assert_eq!(rows[0].summary, "5 flaky specs");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Negative controls: no summary, a summary over 5 lines, non-ASCII text, and a slug that
    /// names a file that is not a report are each refused, and nothing is written.
    #[test]
    fn add_refuses_what_breaks_the_contract() {
        let (dir, p, log) = vault("refuse");
        let now = at("2026-11-24T07:00:00-08:00");
        let err = |n: &New| add(&p, &log, n, now).unwrap_err().to_string();
        assert!(err(&new("T", "  \n", "2026-11-24")).contains("needs a --summary"));
        assert!(err(&new("T", "1\n2\n3\n4\n5\n6", "2026-11-24")).contains("at most 5"));
        assert!(err(&new("Load fell \u{2014} a lot", "s", "2026-11-24")).contains("non-ASCII"));
        assert!(err(&new("", "s", "2026-11-24")).contains("--title"));
        fs::create_dir_all(dir.join("journal/refs/2026-11-24")).unwrap();
        fs::write(dir.join("journal/refs/2026-11-24/my-paste.md"), "pasted\n").unwrap();
        assert!(err(&new("My paste", "s", "2026-11-24")).contains("is not a report"));
        assert_eq!(
            fs::read_to_string(dir.join("journal/refs/2026-11-24/my-paste.md")).unwrap(),
            "pasted\n"
        );
        assert!(list(&p, None, false, false).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    /// The index lists Needs you, Reports, Digests and Your notes from the files themselves: a
    /// file with no frontmatter is a capture, never a report, and `list` without --all skips it.
    #[test]
    fn the_index_sections_and_a_paste_is_a_capture() {
        let (dir, p, log) = vault("index");
        let refs = dir.join("journal/refs/2026-11-24");
        fs::create_dir_all(&refs).unwrap();
        fs::write(
            refs.join("briefing.md"),
            "---\ngenerated: true\n---\n\n# Briefing\n",
        )
        .unwrap();
        fs::write(
            refs.join("agnostic-ci.md"),
            "nd: a pasted transcript tail\n",
        )
        .unwrap();
        fs::write(
            refs.join("_index.md"),
            "---\nid: \"2026-11-24-refs\"\n---\n# Refs\n",
        )
        .unwrap();
        let mut ups = new(
            "UPS switch: did it work?",
            "Load fell 76% -> 41%\nreplug needed",
            "2026-11-24",
        );
        ups.needs_you = true;
        add(&p, &log, &ups, at("2026-11-24T15:40:00-08:00")).unwrap();
        add(
            &p,
            &log,
            &new("Board cleanup", "212 -> 168 rows", "2026-11-24"),
            at("2026-11-24T11:15:00-08:00"),
        )
        .unwrap();

        let index = fs::read_to_string(refs.join("_index.md")).unwrap();
        let want = "## Needs you\n\n- [[journal/refs/2026-11-24/ups-switch-did-it-work|UPS switch: did it work?]]: Load fell 76% -> 41%\n\n## Reports\n\n- [[journal/refs/2026-11-24/board-cleanup|Board cleanup]]: 212 -> 168 rows\n\n## Digests\n\n- [[journal/refs/2026-11-24/briefing|Briefing]]\n\n## Your notes\n\n- [[journal/refs/2026-11-24/agnostic-ci|agnostic-ci]]\n";
        assert!(index.starts_with("---\ngenerated: true\n"), "{index}");
        assert!(index.ends_with(want), "{index}");

        let reports = list(&p, None, false, false);
        assert_eq!(
            reports.iter().map(|e| e.stem.as_str()).collect::<Vec<_>>(),
            ["ups-switch-did-it-work", "board-cleanup"]
        );
        let every = list(&p, None, false, true);
        let kind = |s: &str| every.iter().find(|e| e.stem == s).unwrap().kind;
        assert_eq!(kind("agnostic-ci"), Kind::Capture);
        assert_eq!(kind("briefing"), Kind::Digest);
        assert!(every.iter().all(|e| e.stem != INDEX));

        // Reading the needs-you report moves it out of Needs you.
        read(
            &p,
            &log,
            "2026-11-24-ups-switch-did-it-work",
            at("2026-11-24T16:00:00-08:00"),
        )
        .unwrap();
        let index = fs::read_to_string(refs.join("_index.md")).unwrap();
        assert!(!index.contains("## Needs you"), "{index}");
        let _ = fs::remove_dir_all(&dir);
    }

    /// A legacy archived day is found by list, read and the link resolver, and its index links
    /// files where they are.
    #[test]
    fn a_legacy_archive_day_resolves() {
        let (dir, p, log) = vault("archive");
        let old = dir.join("journal/refs/archive/2026/2026-10/2026-10-03");
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("notes.md"), "a capture\n").unwrap();
        assert_eq!(day_dir(&p, d("2026-10-03")), old);
        add(
            &p,
            &log,
            &new("Old audit", "it was fine", "2026-10-03"),
            at("2026-10-03T08:00:00-07:00"),
        )
        .unwrap();
        assert!(
            old.join("old-audit.md").is_file(),
            "a write to an archived day stays there"
        );
        assert!(!dir.join("journal/refs/2026-10-03").exists());

        let rows = list(&p, Some(d("2026-10-01")), false, false);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].target(&p),
            "journal/refs/archive/2026/2026-10/2026-10-03/old-audit"
        );
        assert!(
            !rows[0].stream(d("2026-11-24")),
            "an old unread report is in the archive"
        );
        assert!(list(&p, Some(d("2026-11-01")), false, false).is_empty());
        read(
            &p,
            &log,
            "2026-10-03-old-audit",
            at("2026-11-24T08:00:00-08:00"),
        )
        .unwrap();

        assert_eq!(
            archived_target(&p, "journal/refs/2026-10-03/notes").as_deref(),
            Some("journal/refs/archive/2026/2026-10/2026-10-03/notes")
        );
        assert_eq!(archived_target(&p, "outbox"), None);
        assert_eq!(archived_target(&p, "journal/refs/notadate/x"), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn slugs_and_ids() {
        assert_eq!(
            slugify("UPS switch: did moving the CI boxes cut the load?"),
            "ups-switch-did-moving-the-ci-boxes-cut-the-load"
        );
        assert_eq!(slugify("  --  "), "");
        assert!(valid_slug("night-shift"));
        assert!(
            !valid_slug("Night-shift")
                && !valid_slug("a--b")
                && !valid_slug("-a")
                && !valid_slug("../x")
        );
        let (dir, p, _) = vault("ids");
        assert!(find(&p, "2026-11-24").is_err());
        assert!(find(&p, "2026-11-24-../../x").is_err());
        assert!(find(&p, "2026-11-24-missing")
            .unwrap_err()
            .to_string()
            .contains("no report"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn frontmatter_reads_quoted_values_and_blocks() {
        let fm = frontmatter("---\ntitle: \"a \\\"q\\\" b\"\nsummary: |-\n  one\n  two\nread: \"\"\nplain: x\n---\nbody").unwrap();
        assert_eq!(fm["title"], "a \"q\" b");
        assert_eq!(fm["summary"], "one\ntwo");
        assert_eq!(fm["read"], "");
        assert_eq!(fm["plain"], "x");
        assert_eq!(body_of("---\na: b\n---\n\n# T\n"), "\n# T\n");
        assert_eq!(body_of("# T\n"), "# T\n");
    }
}
