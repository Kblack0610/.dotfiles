//! `notes report add|list|read|archive|migrate`: the one writer and reader of the reports agents
//! file for the human, which live in `~/.notes/inbox/` and nothing else does.
//!
//! The inbox holds one folder per day, `inbox/<date>/<slug>.md`, each file a **report**
//! (frontmatter `kind: report`, written only by [`add`]). `status/inbox.md` is the one inbox
//! page, and its Reports section reads this folder ([`inbox_lines`]); no index file is written.
//! Past days move to `inbox/archive/YYYY-MM/<date>/` nightly ([`archive_past`]).
//!
//! `journal/refs/<date>/` holds the other two kinds, told apart by a field, never a filename
//! list, and `list --all` reads them too:
//!   - a **digest**: frontmatter `generated: true` (the briefing, agents, shipped, infra-cleanup);
//!   - a **capture**: anything else, the human's own pastes and notes.
//!
//! Read and archived are states on a report, not file moves: `read:` is set by [`read`], and a
//! report is in the stream while it is today's or unread and under [`STREAM_DAYS`] old. Every
//! reader walks the folders live, so a hand-dropped file shows up without a rebuild. A refs day
//! lives in `refs/<date>/`, or in `refs/archive/YYYY/YYYY-MM/<date>/` once [`archive_past`]
//! moved it; [`refs_day_dir`] and [`inbox_day_dir`] are the resolvers.

use crate::config::{Profile, INBOX_DIR};
use crate::knowledge_gate::body;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, FixedOffset, Local, NaiveDate};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// The refs day index's file stem. Generated, never edited by hand.
pub const INDEX: &str = "_index";
/// Where old day folders go, under the inbox root (`archive/YYYY-MM/<date>`) and under the refs
/// root (`archive/YYYY/YYYY-MM/<date>`).
pub const ARCHIVE: &str = "archive";
/// A refs day folder stays live this many days, then [`archive_past`] moves it.
pub const REFS_LIVE_DAYS: i64 = 7;
/// A summary is at most this many lines: it is what the inbox page and the Reports tab show.
const MAX_SUMMARY_LINES: usize = 5;
/// An unread report stays in the stream this many days, then drops to the archive.
pub const STREAM_DAYS: i64 = 7;

#[derive(clap::Subcommand)]
pub enum Cmd {
    /// File a report in `inbox/<date>/` (or revise one: the same slug on the same day updates
    /// it in place and marks it unread)
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
    /// The reports across days, newest first, read live from the inbox folders
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
        /// The refs digests and captures too, each with its `kind`
        #[arg(long, conflicts_with = "unread")]
        all: bool,
    },
    /// Mark a report read by its id (`<date>-<slug>`)
    Read { id: String },
    /// Move past days out of the live folders: inbox days before today into `inbox/archive/`,
    /// refs days over a week old into `refs/archive/`. The nightly `notes summarize` runs it.
    Archive {
        /// Only say what would move
        #[arg(long)]
        dry_run: bool,
    },
    /// Move every `kind: report` file out of `journal/refs/` (live and archived) into the
    /// inbox, then archive. One-time and safe to run again.
    Migrate,
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
            refresh_inbox(p, log);
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
            refresh_inbox(p, log);
            Ok(0)
        }
        Cmd::Archive { dry_run } => {
            println!("{}", archive_today(p, log, dry_run)?.summary(dry_run));
            Ok(0)
        }
        Cmd::Migrate => {
            let m = migrate(p, log, now.date_naive())?;
            println!("{}", m.summary());
            refresh_inbox(p, log);
            Ok(if m.conflicts.is_empty() { 0 } else { 1 })
        }
    }
}

/// Republish the inbox page, whose Reports section lists the stream, so a report filed, read or
/// archived shows there now rather than at the next sweep. The report is already written: a page that
/// cannot be published says so and does not fail the command.
fn refresh_inbox(p: &Profile, log: &Logger) {
    if let Err(e) = crate::daily::publish_inbox_page_kept_score(p, log) {
        eprintln!("(inbox page not refreshed: {e:#})");
    }
}

fn parse_day(s: &str) -> Result<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").with_context(|| format!("'{s}' is not YYYY-MM-DD"))
}

fn stamp(t: DateTime<FixedOffset>) -> String {
    t.format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

// ---- where a day lives ----

fn day_name(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

fn inbox_live(p: &Profile, day: NaiveDate) -> PathBuf {
    p.inbox().join(day_name(day))
}

fn inbox_archived(p: &Profile, day: NaiveDate) -> PathBuf {
    p.inbox()
        .join(ARCHIVE)
        .join(day.format("%Y-%m").to_string())
        .join(day_name(day))
}

fn refs_live(p: &Profile, day: NaiveDate) -> PathBuf {
    p.refs.join(day_name(day))
}

fn refs_archived(p: &Profile, day: NaiveDate) -> PathBuf {
    p.refs
        .join(ARCHIVE)
        .join(day.format("%Y").to_string())
        .join(day.format("%Y-%m").to_string())
        .join(day_name(day))
}

/// `live`, unless only `old` exists: where a read finds a day and a new write goes.
fn resolve(live: PathBuf, old: PathBuf) -> PathBuf {
    if !live.is_dir() && old.is_dir() {
        old
    } else {
        live
    }
}

/// The folder that holds `day`'s reports: `inbox/<date>/`, else the archive folder when only
/// that exists, else `inbox/<date>/` (where a new write goes).
pub fn inbox_day_dir(p: &Profile, day: NaiveDate) -> PathBuf {
    resolve(inbox_live(p, day), inbox_archived(p, day))
}

/// The same for `day`'s refs folder (digests and captures).
fn refs_day_dir(p: &Profile, day: NaiveDate) -> PathBuf {
    resolve(refs_live(p, day), refs_archived(p, day))
}

/// Where a `[[journal/refs/<date>/<rest>]]` link's file may have gone when the live path does
/// not exist, in the order to try: the refs archive, then the inbox (a report [`migrate`] moved),
/// live and archived. Empty for a target outside refs or without a date. The link resolver
/// (`notes show`) tries each, so a link written before a move keeps working.
pub fn moved_targets(p: &Profile, target: &str) -> Vec<String> {
    let Some(rest) = target
        .strip_prefix(p.refs_rel.as_str())
        .and_then(|r| r.strip_prefix('/'))
    else {
        return Vec::new();
    };
    let Some((date, tail)) = rest.split_once('/') else {
        return Vec::new();
    };
    let Ok(day) = NaiveDate::parse_from_str(date, "%Y-%m-%d") else {
        return Vec::new();
    };
    let (year, month) = (day.format("%Y"), day.format("%Y-%m"));
    vec![
        format!("{}/{ARCHIVE}/{year}/{month}/{date}/{tail}", p.refs_rel),
        format!("{INBOX_DIR}/{date}/{tail}"),
        format!("{INBOX_DIR}/{ARCHIVE}/{month}/{date}/{tail}"),
    ]
}

/// `path` as a wikilink target: relative to `root` under `rel_root`, without `.md`.
fn rooted_target(root: &Path, rel_root: &str, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    let rel = rel.to_string_lossy();
    format!("{rel_root}/{}", rel.strip_suffix(".md").unwrap_or(&rel))
}

/// The wikilink target of `day`'s refs index, in the folder it is written to (an archived day's
/// index lives in the archive).
pub fn index_target(p: &Profile, day: NaiveDate) -> String {
    rooted_target(&p.refs, &p.refs_rel, &refs_day_dir(p, day).join(INDEX))
}

/// The subfolders of `dir` named for a day, as `(day, dir)`.
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

/// The subfolders of `dir`, any name (an archive's `YYYY` and `YYYY-MM` levels).
fn subdirs(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}

/// Every day folder under `root`, live and archived, as `(day, dir)`, oldest first. `levels` is
/// how many folders sit between `archive/` and a day: 2 under refs (`YYYY/YYYY-MM`), 1 under
/// the inbox (`YYYY-MM`). A day split between a live and an archived folder (the nightly left a
/// differing file behind, or a write made the live one again) appears once per folder, so a
/// reader sees every file; a writer picks the one folder through the `*_day_dir` resolvers.
fn days_in(root: &Path, levels: usize) -> Vec<(NaiveDate, PathBuf)> {
    let mut tiers = vec![root.join(ARCHIVE)];
    for _ in 0..levels {
        tiers = tiers.iter().flat_map(|d| subdirs(d)).collect();
    }
    let mut out: Vec<(NaiveDate, PathBuf)> = tiers.iter().flat_map(|d| dated(d)).collect();
    out.extend(dated(root));
    out.sort();
    out
}

// ---- the contract ----

/// `---`-fenced frontmatter at the top of `content`: `key: value` lines, a `"..."` value
/// unquoted as JSON (the writer quotes with JSON, which YAML reads too), and a `key: |-` block
/// taking the indented lines under it. None when there is no frontmatter.
fn frontmatter(content: &str) -> Option<BTreeMap<String, String>> {
    let rest = content.strip_prefix("---\n")?;
    let body = body(content);
    if body.len() == content.len() {
        return None;
    }
    let mut out = BTreeMap::new();
    let mut lines = rest[..rest.len() - body.len()]
        .lines()
        .take_while(|l| l.trim_end() != "---")
        .peekable();
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

    /// The wikilink target: the root-relative path, so an archived day links where it is.
    fn target(&self, p: &Profile) -> String {
        match self.kind {
            Kind::Report => rooted_target(&p.inbox(), INBOX_DIR, &self.path),
            Kind::Digest | Kind::Capture => rooted_target(&p.refs, &p.refs_rel, &self.path),
        }
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

    /// The summary's first line, for the inbox page.
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
        body(&content)
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
fn dir_entries(day: NaiveDate, dir: &Path) -> Vec<Entry> {
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

/// The digests and captures in a refs day folder. A report left there is [`migrate`]'s to move,
/// so it is neither indexed nor listed.
fn refs_entries(day: NaiveDate, dir: &Path) -> Vec<Entry> {
    let mut out = dir_entries(day, dir);
    out.retain(|e| e.kind != Kind::Report);
    out
}

// ---- the refs index ----

/// A wikilink label: no character that ends or splits the link.
fn label(s: &str) -> String {
    s.replace('|', "/").replace(['[', ']'], "")
}

/// A refs day's `_index.md` text, built from its entries: Digests, then Your notes.
pub fn index_text(p: &Profile, day: NaiveDate, all: &[Entry]) -> String {
    let link = |e: &Entry| format!("- [[{}|{}]]", e.target(p), label(&e.title));
    let mut s = format!(
        "---\ngenerated: true\ntags: [refs]\n---\n\n# Refs {}\n\nBuilt by `notes link-refs` from this folder; edits here are overwritten.\n",
        day.format("%Y-%m-%d")
    );
    let (mut digests, mut notes) = (Vec::new(), Vec::new());
    for e in all {
        match e.kind {
            Kind::Digest => digests.push(link(e)),
            Kind::Capture => notes.push(link(e)),
            Kind::Report => {}
        }
    }
    for (heading, lines) in [("Digests", digests), ("Your notes", notes)] {
        if !lines.is_empty() {
            s.push_str(&format!("\n## {heading}\n\n{}\n", lines.join("\n")));
        }
    }
    if all.is_empty() {
        s.push_str("\nNothing filed yet.\n");
    }
    s
}

/// The inbox page's Reports lines: every report in the stream (today's, or unread and under
/// [`STREAM_DAYS`] old), unread ones that need the human first, then newest first. Each is the
/// report's link, its summary's first line, and its day when that is not `today`. Read live
/// from the folders, as every reader here is, so the page needs no copy of the list.
pub fn inbox_lines(p: &Profile, today: NaiveDate) -> Vec<String> {
    let since = today - chrono::Duration::days(STREAM_DAYS);
    let mut shown: Vec<Entry> = list(p, Some(since), false, false)
        .into_iter()
        .filter(|e| e.stream(today))
        .collect();
    // `list` is newest day first, newest filed first; a stable sort keeps that within each half.
    shown.sort_by_key(|e| !(e.needs_you && e.unread()));
    shown
        .iter()
        .map(|e| {
            let mut l = format!("[[{}|{}]]", e.target(p), label(&e.title));
            if e.needs_you && e.unread() {
                l.push_str(" (needs you)");
            }
            if e.day != today {
                l.push_str(&format!(" ({})", e.day.format("%m-%d")));
            }
            match e.lead() {
                "" => l,
                lead => format!("{l}: {lead}"),
            }
        })
        .collect()
}

fn lock(p: &Profile) -> Result<md::FileLock> {
    md::lock_file(&p.state_dir.join("report.lock"))
}

/// Rebuild refs `day`'s `_index.md` when its folder exists, writing only on a change, and return
/// the day's entries (empty when there is no folder).
pub fn rebuild_index(p: &Profile, day: NaiveDate) -> Result<Vec<Entry>> {
    let dir = refs_day_dir(p, day);
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let _lock = lock(p)?;
    let all = refs_entries(day, &dir);
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

/// `title` in kebab case (`md::kebab`), at most 60 characters.
fn slugify(title: &str) -> String {
    let mut cut = crate::md::kebab(title).chars().take(60).collect::<String>();
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
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
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

/// A report file: the contract's frontmatter, then `# title`, then the body.
fn render(e: &Entry, body: &str) -> String {
    let mut s = String::from("---\nkind: report\n");
    s.push_str(&format!("id: {}\n", e.id()));
    s.push_str(&format!("title: {}\n", crate::md::yaml_quote(&e.title)));
    s.push_str("summary: |-\n");
    for l in e.summary.lines() {
        s.push_str(&format!("  {l}\n"));
    }
    s.push_str(&format!("from: {}\n", crate::md::yaml_quote(&e.from)));
    s.push_str(&format!("needs_you: {}\n", e.needs_you));
    s.push_str(&format!("created: {}\n", e.created));
    s.push_str(&format!("updated: {}\n", e.updated));
    s.push_str(&format!("read: {}\n", crate::md::yaml_quote(&e.read)));
    s.push_str(&format!("---\n\n# {}\n\n", e.title));
    let body = body.trim();
    if !body.is_empty() {
        s.push_str(body);
        s.push('\n');
    }
    s
}

/// The body without a leading `# heading` (the title is written from `--title`). A report file
/// passed back in (a revision built from the stored report) loses its own frontmatter; any other
/// frontmatter is refused, since the fields come from the flags.
fn clean_body(body: &str) -> Result<String> {
    let body = match frontmatter(body) {
        Some(fm) if fm.get("kind").map(String::as_str) == Some("report") => self::body(body),
        _ if body.starts_with("---\n") => {
            bail!("the body has frontmatter of its own; pass its fields as flags and drop it")
        }
        _ => body,
    };
    let trimmed = body.trim_start();
    let rest = match trimmed.lines().next() {
        Some(first) if first.starts_with("# ") => &trimmed[first.len()..],
        _ => trimmed,
    };
    Ok(rest.trim().to_string())
}

/// File (or revise) a report in `inbox/<date>/`. Returns the file and the id.
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
    let dir = inbox_day_dir(p, new.day);
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
    let id = format!("{}-{slug}", new.day.format("%Y-%m-%d"));
    log.info("report", &format!("filed {id}"));
    Ok((path, id))
}

// ---- list and read ----

/// Reports across every inbox day folder, newest day first and newest first within a day.
/// `since` keeps days on or after it, `unread` only unread reports, `all` adds the refs digests
/// and captures.
pub fn list(p: &Profile, since: Option<NaiveDate>, unread: bool, all: bool) -> Vec<Entry> {
    let keep = |d: &NaiveDate| since.is_none_or(|s| *d >= s);
    let mut out: Vec<Entry> = days_in(&p.inbox(), 1)
        .into_iter()
        .filter(|(d, _)| keep(d))
        .flat_map(|(d, dir)| dir_entries(d, &dir))
        .filter(|e| e.kind == Kind::Report)
        .filter(|e| !unread || e.unread())
        .collect();
    if all {
        out.extend(
            days_in(&p.refs, 2)
                .into_iter()
                .filter(|(d, _)| keep(d))
                .flat_map(|(d, dir)| refs_entries(d, &dir)),
        );
    }
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
    let found = days_in(&p.inbox(), 1)
        .into_iter()
        .filter(|(d, _)| *d == day)
        .find_map(|(_, dir)| entry(day, &dir.join(format!("{slug}.md"))));
    match found {
        Some(e) if e.kind == Kind::Report => Ok(e),
        Some(e) => bail!("{} is not a report", e.path.display()),
        None => bail!("no report {id}"),
    }
}

/// Mark the report `id` read (kept as first read when it already is). Returns its file.
pub fn read(p: &Profile, log: &Logger, id: &str, now: DateTime<FixedOffset>) -> Result<PathBuf> {
    let e = find(p, id)?;
    if e.read.is_empty() {
        let _lock = lock(p)?;
        let content = fs::read_to_string(&e.path)?;
        // Another reader may have marked it since `find`: the first read time stands.
        let still_unread = frontmatter(&content)
            .and_then(|fm| fm.get("read").cloned())
            .is_some_and(|r| r.is_empty());
        if still_unread {
            let marked = content.replacen(
                "\nread: \"\"\n",
                &format!("\nread: {}\n", crate::md::yaml_quote(&stamp(now))),
                1,
            );
            if marked == content {
                bail!("{} has no empty read: field to set", e.path.display());
            }
            md::write_atomic(&e.path, &marked)?;
            log.info("report", &format!("read {id}"));
        }
    }
    Ok(e.path)
}

// ---- archive and migrate ----

/// The day folders [`archive_past`] moved.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Moved {
    pub inbox: usize,
    pub refs: usize,
}

impl Moved {
    fn summary(&self, dry_run: bool) -> String {
        let verb = if dry_run { "would move" } else { "moved" };
        format!(
            "{verb} {} inbox day(s) and {} refs day(s) to the archive",
            self.inbox, self.refs
        )
    }
}

/// Move the day folder `from` to `to`: a rename when `to` is free, else file by file, never
/// overwriting. A file whose twin is already there goes (same bytes); one that differs, or that
/// cannot be compared, stays in `from` for a hand look. `from` goes when it ends empty. True
/// when `from` is gone, so a day that cannot settle is not counted as moved every night.
fn move_day(from: &Path, to: &Path) -> Result<bool> {
    if !to.exists() {
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(from, to)
            .with_context(|| format!("moving {} -> {}", from.display(), to.display()))?;
        return Ok(true);
    }
    for e in fs::read_dir(from)?.flatten() {
        let dest = to.join(e.file_name());
        if !dest.exists() {
            fs::rename(e.path(), &dest)
                .with_context(|| format!("moving {} -> {}", e.path().display(), dest.display()))?;
        } else if e.path().is_file()
            && matches!((fs::read(e.path()), fs::read(&dest)), (Ok(a), Ok(b)) if a == b)
        {
            fs::remove_file(e.path())?;
        }
    }
    Ok(fs::remove_dir(from).is_ok())
}

/// Move `dir` to `to`, a failure warned and the day left where it is, so one bad day does not
/// stop the ones after it. True when the day moved.
fn settle_day(log: &Logger, dir: &Path, to: &Path) -> bool {
    match move_day(dir, to) {
        Ok(done) => done,
        Err(e) => {
            log.warn("report", &format!("{} not archived: {e:#}", dir.display()));
            false
        }
    }
}

/// Move every inbox day folder before `today` into `inbox/archive/YYYY-MM/`, and every refs day
/// folder more than [`REFS_LIVE_DAYS`] old into `refs/archive/YYYY/YYYY-MM/`. Idempotent: a
/// second run finds nothing live to move. `dry_run` only counts. Links to a moved day resolve
/// through [`moved_targets`] and the readers walk the archive, so nothing else changes.
pub fn archive_past(p: &Profile, log: &Logger, today: NaiveDate, dry_run: bool) -> Result<Moved> {
    let _lock = lock(p)?;
    let mut moved = Moved::default();
    for (day, dir) in dated(&p.inbox()).into_iter().filter(|(d, _)| *d < today) {
        if dry_run || settle_day(log, &dir, &inbox_archived(p, day)) {
            moved.inbox += 1;
        }
    }
    let cutoff = today - chrono::Duration::days(REFS_LIVE_DAYS);
    for (day, dir) in dated(&p.refs).into_iter().filter(|(d, _)| *d < cutoff) {
        if dry_run || settle_day(log, &dir, &refs_archived(p, day)) {
            moved.refs += 1;
        }
    }
    if !dry_run && moved != Moved::default() {
        log.info("report", &moved.summary(false));
    }
    Ok(moved)
}

/// The nightly: [`migrate`] (a report an older writer left in refs comes into the inbox, so none
/// is hidden whenever the binary was deployed; with none left it moves nothing), which also
/// archives the past days, then the inbox page republished when anything moved: its links name
/// the folder a report is in. A conflict is warned, never fatal. `notes summarize` and
/// `report archive` run it. `dry_run` only counts the archive.
pub fn archive_today(p: &Profile, log: &Logger, dry_run: bool) -> Result<Moved> {
    let today = Local::now().date_naive();
    if dry_run {
        return archive_past(p, log, today, true);
    }
    let m = migrate(p, log, today)?;
    for c in &m.conflicts {
        log.warn(
            "report",
            &format!("conflict, left in refs: {}", c.display()),
        );
    }
    if m.moved + m.duplicates > 0 || m.archived.inbox > 0 {
        refresh_inbox(p, log);
    }
    Ok(m.archived)
}

/// What [`migrate`] did.
#[derive(Debug, Default)]
pub struct Migrated {
    /// Reports moved from refs into the inbox.
    pub moved: usize,
    /// Reports already in the inbox with the same bytes, removed from refs.
    pub duplicates: usize,
    /// Reports whose inbox twin differs: left in refs, for a hand look.
    pub conflicts: Vec<PathBuf>,
    pub archived: Moved,
}

impl Migrated {
    fn summary(&self) -> String {
        let mut s = format!(
            "moved {} report(s) into the inbox, removed {} duplicate(s); {}",
            self.moved,
            self.duplicates,
            self.archived.summary(false)
        );
        for c in &self.conflicts {
            s.push_str(&format!("\nconflict, left in place: {}", c.display()));
        }
        s
    }
}

/// Move every `kind: report` file out of the refs day folders, live and archived, into the
/// inbox (`inbox/<date>/`), then archive the past days. Each touched refs day gets its index
/// rebuilt without the reports, or loses the folder when only the index was left. Idempotent: a
/// second run finds no report in refs.
pub fn migrate(p: &Profile, log: &Logger, today: NaiveDate) -> Result<Migrated> {
    let mut m = Migrated::default();
    let mut touched: Vec<(NaiveDate, PathBuf)> = Vec::new();
    {
        let _lock = lock(p)?;
        for (day, dir) in days_in(&p.refs, 2) {
            for e in dir_entries(day, &dir)
                .into_iter()
                .filter(|e| e.kind == Kind::Report)
            {
                let Some(name) = e.path.file_name() else {
                    continue;
                };
                let dest_dir = inbox_day_dir(p, day);
                let dest = dest_dir.join(name);
                if !dest.exists() {
                    fs::create_dir_all(&dest_dir)?;
                    fs::rename(&e.path, &dest).with_context(|| {
                        format!("moving {} -> {}", e.path.display(), dest.display())
                    })?;
                    m.moved += 1;
                } else if fs::read(&e.path)? == fs::read(&dest)? {
                    fs::remove_file(&e.path)?;
                    m.duplicates += 1;
                } else {
                    m.conflicts.push(e.path.clone());
                    continue;
                }
                if !touched.iter().any(|(_, d)| *d == dir) {
                    touched.push((day, dir.clone()));
                }
            }
        }
    }
    for (day, dir) in touched {
        if refs_entries(day, &dir).is_empty() {
            let _ = fs::remove_file(dir.join(format!("{INDEX}.md")));
            let _ = fs::remove_dir(&dir);
        }
        if let Err(e) = crate::daily::link_day_refs(p, log, day) {
            log.warn("report", &format!("refs index of {day} not rebuilt: {e:#}"));
        }
    }
    m.archived = archive_past(p, log, today, false)?;
    if m.moved + m.duplicates > 0 || !m.conflicts.is_empty() {
        log.info("report", &m.summary());
    }
    Ok(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::md::date as d;

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
            "  4 flaky specs\n2 quarantined",
            "2026-11-24",
        );
        n.body = "# Old heading\n\nThe table.\n".into();
        let (path, id) = add(&p, &log, &n, at("2026-11-24T07:02:00-08:00")).unwrap();
        assert_eq!(id, "2026-11-24-nightly-flake-readout");
        assert_eq!(path, dir.join("inbox/2026-11-24/nightly-flake-readout.md"));
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("---\nkind: report\nid: 2026-11-24-nightly-flake-readout\ntitle: \"Nightly flake readout\"\nsummary: |-\n  4 flaky specs\n  2 quarantined\nfrom: \"item-1\"\nneeds_you: false\ncreated: 2026-11-24T07:02:00-08:00\nupdated: 2026-11-24T07:02:00-08:00\nread: \"\"\n---\n\n# Nightly flake readout\n\nThe table.\n"), "{text}");

        let rows = list(&p, None, false, false);
        assert_eq!(rows.len(), 1);
        let j = rows[0].json(&p, d("2026-11-24"));
        assert_eq!(j["summary"], "4 flaky specs\n2 quarantined");
        assert_eq!(j["read"], Value::Null);
        assert_eq!(j["stream"], true);
        assert_eq!(j["target"], "inbox/2026-11-24/nightly-flake-readout");
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

        // The stored report passed back as the body, with a section appended: one frontmatter,
        // one title, the old body kept.
        n.body = format!(
            "{}\n## Morning\n\nAll green.\n",
            fs::read_to_string(&path).unwrap()
        );
        add(&p, &log, &n, at("2026-11-24T11:00:00-08:00")).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(text.matches("kind: report").count(), 1, "{text}");
        assert!(
            text.ends_with(
                "\n---\n\n# Nightly flake readout\n\nThe table.\n\n## Morning\n\nAll green.\n"
            ),
            "{text}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// The inbox page's Reports: the stream only, an unread needs-you report first, an older
    /// day's report dated, a read one from an older day gone (the archive), and a digest never.
    #[test]
    fn inbox_lines_are_the_stream_needs_you_first() {
        let (dir, p, log) = vault("inbox");
        let today = d("2026-11-24");
        add(
            &p,
            &log,
            &new("Fresh audit", "All clear.", "2026-11-24"),
            at("2026-11-24T09:00:00-08:00"),
        )
        .unwrap();
        let mut urgent = new(
            "Sign the BAA",
            "One form waits.\nSecond line.",
            "2026-11-23",
        );
        urgent.needs_you = true;
        add(&p, &log, &urgent, at("2026-11-23T08:00:00-08:00")).unwrap();
        let (_, old_id) = add(
            &p,
            &log,
            &new("Old read", "Done.", "2026-11-22"),
            at("2026-11-22T08:00:00-08:00"),
        )
        .unwrap();
        read(&p, &log, &old_id, at("2026-11-23T08:00:00-08:00")).unwrap();
        add(
            &p,
            &log,
            &new("Too old", "Stale.", "2026-11-10"),
            at("2026-11-10T08:00:00-08:00"),
        )
        .unwrap();
        fs::create_dir_all(dir.join("journal/refs/2026-11-24")).unwrap();
        fs::write(
            dir.join("journal/refs/2026-11-24/briefing.md"),
            "---\ngenerated: true\n---\n# Briefing\n",
        )
        .unwrap();
        assert_eq!(
            inbox_lines(&p, today),
            [
                "[[inbox/2026-11-23/sign-the-baa|Sign the BAA]] (needs you) (11-23): One form waits.",
                "[[inbox/2026-11-24/fresh-audit|Fresh audit]]: All clear.",
            ]
        );
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
        let mut fm = new("T", "s", "2026-11-24");
        fm.body = "---\ntags: [x]\n---\nbody\n".into();
        assert!(err(&fm).contains("frontmatter of its own"));
        fs::create_dir_all(dir.join("inbox/2026-11-24")).unwrap();
        fs::write(dir.join("inbox/2026-11-24/my-paste.md"), "pasted\n").unwrap();
        assert!(err(&new("My paste", "s", "2026-11-24")).contains("is not a report"));
        assert_eq!(
            fs::read_to_string(dir.join("inbox/2026-11-24/my-paste.md")).unwrap(),
            "pasted\n"
        );
        assert!(list(&p, None, false, false).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    /// The refs index lists Digests and Your notes from the files themselves, and no report:
    /// a file with no frontmatter is a capture, `list` skips it without --all, a report left in
    /// refs is neither indexed nor listed, and filing a report writes no index anywhere.
    #[test]
    fn the_refs_index_lists_digests_and_notes_and_a_paste_is_a_capture() {
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
            refs.join("stray.md"),
            "---\nkind: report\ntitle: \"Stray\"\n---\n# Stray\n",
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
        assert_eq!(
            fs::read_to_string(refs.join("_index.md")).unwrap(),
            "---\nid: \"2026-11-24-refs\"\n---\n# Refs\n",
            "filing a report leaves the refs index alone"
        );
        assert!(!dir.join("inbox/2026-11-24/_index.md").exists());

        rebuild_index(&p, d("2026-11-24")).unwrap();
        let index = fs::read_to_string(refs.join("_index.md")).unwrap();
        let want = "## Digests\n\n- [[journal/refs/2026-11-24/briefing|Briefing]]\n\n## Your notes\n\n- [[journal/refs/2026-11-24/agnostic-ci|agnostic-ci]]\n";
        assert!(index.starts_with("---\ngenerated: true\n"), "{index}");
        assert!(index.ends_with(want), "{index}");
        assert!(
            !index.contains("Stray") && !index.contains("UPS"),
            "{index}"
        );

        let reports = list(&p, None, false, false);
        assert_eq!(
            reports.iter().map(|e| e.stem.as_str()).collect::<Vec<_>>(),
            ["ups-switch-did-it-work", "board-cleanup"]
        );
        let every = list(&p, None, false, true);
        let kind = |s: &str| every.iter().find(|e| e.stem == s).unwrap().kind;
        assert_eq!(kind("agnostic-ci"), Kind::Capture);
        assert_eq!(kind("briefing"), Kind::Digest);
        assert_eq!(kind("board-cleanup"), Kind::Report);
        assert!(every.iter().all(|e| e.stem != INDEX && e.stem != "stray"));
        let _ = fs::remove_dir_all(&dir);
    }

    /// An archived inbox day is found by list, read and add; an archived refs day by list --all,
    /// the refs index and the link resolver; and a refs link to a moved report resolves to the
    /// inbox, live or archived.
    #[test]
    fn an_archived_day_resolves() {
        let (dir, p, log) = vault("archive");
        let old = dir.join("inbox/archive/2026-10/2026-10-03");
        fs::create_dir_all(&old).unwrap();
        assert_eq!(inbox_day_dir(&p, d("2026-10-03")), old);
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
        assert!(!dir.join("inbox/2026-10-03").exists());

        let rows = list(&p, Some(d("2026-10-01")), false, false);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].target(&p),
            "inbox/archive/2026-10/2026-10-03/old-audit"
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
        assert!(list(&p, None, true, false).is_empty());
        // A split day (a live folder made after the archive) is read from both folders.
        let live = dir.join("inbox/2026-10-03");
        fs::create_dir_all(&live).unwrap();
        let split: Vec<_> = days_in(&p.inbox(), 1)
            .into_iter()
            .filter(|(day, _)| *day == d("2026-10-03"))
            .collect();
        assert_eq!(
            split,
            vec![
                (d("2026-10-03"), live.clone()),
                (d("2026-10-03"), old.clone())
            ],
            "both halves are read"
        );
        assert!(
            find(&p, "2026-10-03-old-audit").is_ok(),
            "read finds the archived half"
        );
        fs::remove_dir_all(&live).unwrap();

        let refs_old = dir.join("journal/refs/archive/2026/2026-10/2026-10-03");
        fs::create_dir_all(&refs_old).unwrap();
        fs::write(refs_old.join("notes.md"), "a capture\n").unwrap();
        assert_eq!(refs_day_dir(&p, d("2026-10-03")), refs_old);
        assert_eq!(
            index_target(&p, d("2026-10-03")),
            "journal/refs/archive/2026/2026-10/2026-10-03/_index"
        );
        assert_eq!(
            list(&p, None, false, true).len(),
            2,
            "the report and the capture"
        );

        assert_eq!(
            moved_targets(&p, "journal/refs/2026-10-03/notes"),
            [
                "journal/refs/archive/2026/2026-10/2026-10-03/notes",
                "inbox/2026-10-03/notes",
                "inbox/archive/2026-10/2026-10-03/notes",
            ]
        );
        assert!(moved_targets(&p, "outbox").is_empty());
        assert!(moved_targets(&p, "journal/refs/notadate/x").is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    /// The nightly archive: an inbox day before today moves under `archive/YYYY-MM/`, today's
    /// stays, a refs day over a week old moves under `refs/archive/YYYY/YYYY-MM/` and a recent
    /// one stays, a second run moves nothing, and a day that already has an archive folder
    /// merges into it without overwriting.
    #[test]
    fn archive_past_moves_old_days_and_is_idempotent() {
        let (dir, p, log) = vault("nightly");
        let now = at("2026-11-26T01:00:00-08:00");
        let today = d("2026-11-26");
        for day in ["2026-11-24", "2026-11-25", "2026-11-26"] {
            add(&p, &log, &new(day, "s", day), now).unwrap();
        }
        for day in ["2026-11-10", "2026-11-19", "2026-11-26"] {
            let refs = dir.join("journal/refs").join(day);
            fs::create_dir_all(&refs).unwrap();
            fs::write(refs.join("briefing.md"), "---\ngenerated: true\n---\n").unwrap();
        }
        let dry = archive_past(&p, &log, today, true).unwrap();
        assert_eq!(dry, Moved { inbox: 2, refs: 1 });
        assert!(
            dir.join("inbox/2026-11-24").is_dir(),
            "a dry run moves nothing"
        );

        let moved = archive_past(&p, &log, today, false).unwrap();
        assert_eq!(moved, Moved { inbox: 2, refs: 1 });
        assert!(dir
            .join("inbox/archive/2026-11/2026-11-24/2026-11-24.md")
            .is_file());
        assert!(dir.join("inbox/archive/2026-11/2026-11-25").is_dir());
        assert!(dir.join("inbox/2026-11-26").is_dir());
        assert!(!dir.join("inbox/2026-11-24").exists());
        assert!(dir
            .join("journal/refs/archive/2026/2026-11/2026-11-10/briefing.md")
            .is_file());
        assert!(dir.join("journal/refs/2026-11-19").is_dir());
        assert_eq!(
            archive_past(&p, &log, today, false).unwrap(),
            Moved::default()
        );
        assert_eq!(
            list(&p, None, false, false).len(),
            3,
            "the archive is still read"
        );

        // A day that already has an archive folder merges: a new file moves, an identical one
        // goes, a different one stays where it is.
        let live = dir.join("inbox/2026-11-24");
        fs::create_dir_all(&live).unwrap();
        let arch = dir.join("inbox/archive/2026-11/2026-11-24");
        fs::write(
            live.join("2026-11-24.md"),
            fs::read(arch.join("2026-11-24.md")).unwrap(),
        )
        .unwrap();
        fs::write(live.join("late.md"), "late\n").unwrap();
        fs::write(arch.join("clash.md"), "one\n").unwrap();
        fs::write(live.join("clash.md"), "two\n").unwrap();
        archive_past(&p, &log, today, false).unwrap();
        assert!(arch.join("late.md").is_file());
        assert!(!live.join("2026-11-24.md").exists());
        assert_eq!(fs::read_to_string(live.join("clash.md")).unwrap(), "two\n");
        assert_eq!(fs::read_to_string(arch.join("clash.md")).unwrap(), "one\n");
        let _ = fs::remove_dir_all(&dir);
    }

    /// The one-time move of reports out of refs: live and archived refs days both land in the
    /// inbox (then past days archive), digests and captures stay, a day left with only its index
    /// loses the folder, a day with a digest gets its index rebuilt without the report, an
    /// identical twin is dropped, a different twin is a conflict left in place, and a second run
    /// does nothing.
    #[test]
    fn migrate_moves_reports_out_of_refs_once() {
        let (dir, p, log) = vault("migrate");
        let today = d("2026-11-26");
        let report = |title: &str| {
            format!("---\nkind: report\ntitle: \"{title}\"\nread: \"\"\n---\n\n# {title}\n")
        };
        let live = dir.join("journal/refs/2026-11-25");
        let old = dir.join("journal/refs/archive/2026/2026-10/2026-10-03");
        let only = dir.join("journal/refs/2026-11-24");
        for d in [&live, &old, &only] {
            fs::create_dir_all(d).unwrap();
        }
        fs::write(live.join("a.md"), report("A")).unwrap();
        fs::write(live.join("briefing.md"), "---\ngenerated: true\n---\n# B\n").unwrap();
        fs::write(live.join("paste.md"), "pasted\n").unwrap();
        fs::write(live.join("_index.md"), "stale index listing A\n").unwrap();
        fs::write(old.join("b.md"), report("B")).unwrap();
        fs::write(only.join("c.md"), report("C")).unwrap();
        fs::write(only.join("_index.md"), "stale\n").unwrap();
        fs::create_dir_all(dir.join("inbox/2026-11-25")).unwrap();
        fs::write(dir.join("inbox/2026-11-25/a.md"), report("A")).unwrap();

        let m = migrate(&p, &log, today).unwrap();
        assert_eq!(
            (m.moved, m.duplicates, m.conflicts.len()),
            (2, 1, 0),
            "{m:?}"
        );
        assert_eq!(m.archived, Moved { inbox: 3, refs: 0 });
        for f in [
            "inbox/archive/2026-11/2026-11-25/a.md",
            "inbox/archive/2026-11/2026-11-24/c.md",
            "inbox/archive/2026-10/2026-10-03/b.md",
        ] {
            assert!(dir.join(f).is_file(), "{f}");
        }
        assert!(live.join("paste.md").is_file() && live.join("briefing.md").is_file());
        assert!(!live.join("a.md").exists());
        let index = fs::read_to_string(live.join("_index.md")).unwrap();
        assert!(
            index.contains("[[journal/refs/2026-11-25/briefing|B]]"),
            "{index}"
        );
        assert!(!index.contains("listing A"), "{index}");
        assert!(!only.exists(), "a day left with only its index goes");
        assert_eq!(list(&p, None, false, false).len(), 3);
        assert_eq!(list(&p, None, false, true).len(), 5);

        // A second run does nothing.
        let again = migrate(&p, &log, today).unwrap();
        assert_eq!(
            (again.moved, again.duplicates, again.conflicts.len()),
            (0, 0, 0)
        );
        assert_eq!(again.archived, Moved::default());

        // A twin that differs stays in refs and is named.
        fs::write(live.join("a.md"), report("A, revised")).unwrap();
        let clash = migrate(&p, &log, today).unwrap();
        assert_eq!(clash.conflicts, vec![live.join("a.md")]);
        assert!(live.join("a.md").is_file());
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
        assert_eq!(body("---\na: b\n---\n\n# T\n"), "\n# T\n");
        assert_eq!(body("# T\n"), "# T\n");
        // An empty block, and a `---` rule in the body, end where the first `---` line does.
        assert!(frontmatter("---\n---\n# T\n").unwrap().is_empty());
        assert_eq!(frontmatter("---\na: b\n---\nx\n---\n").unwrap().len(), 1);
        assert!(frontmatter("# T\n").is_none());
    }
}
