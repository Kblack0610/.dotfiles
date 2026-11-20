//! `notes knowledge` - the write side of the compiled knowledge base under `knowledge/`.
//!
//! The nightly knowledge engine is a model with READ-only tools. It never writes a file: it
//! hands back a batch of ops as JSON, and `apply` is the one writer. That keeps every guard
//! in tested code instead of in a prompt:
//!
//!   - an op may only touch `knowledge/**/*.md`, never `knowledge/_log/`, the schema or the
//!     README (both generated: `write_schema`, `write_readme`);
//!   - a new page goes under a domain of the registry (`knowledge_registry.rs`), with a slug
//!     that names a topic, not a date;
//!   - tags come from the schema, and the vault sources an op cites are in its `sources`;
//!   - a core page links its canonical doc, and a project page never restates a core topic;
//!   - an update loses to a human edit made while the engine was running (`--started`);
//!   - an update may not silently gut an article (the shrink guard);
//!   - an op may not add a line that names a retired host or command as live (`--retired`,
//!     `knowledge_retired.rs`), so a sold machine is never written back as a host;
//!   - a hand-written article is copied to `_log/originals/` the first time it is rewritten;
//!   - every date gets exactly one immutable log, `_log/YYYY/MM/YYYY-MM-DD.md`, which is also
//!     the checkpoint: git syncs it, so no machine re-runs a date another already did.
//!
//! `morning_lines` renders the knowledge half of the daily note's `## Morning` from those logs.

use crate::config::{self, Profile};
use crate::knowledge_registry::{self as registry, Domain, Kind, Registry};
use crate::knowledge_retired::List;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::{Duration, NaiveDate};
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

const SCHEMA_TEMPLATE: &str = include_str!("knowledge_schema.md");
pub(crate) const SCHEMA_FILE: &str = "SCHEMA.md";
const README_TEMPLATE: &str = include_str!("knowledge_readme.md");
const README_FILE: &str = "README.md";
const LOG_DIR: &str = "_log";
/// A batch bigger than this is a model that lost the plot, not a busy night.
const MAX_OPS: usize = 20;
/// An update may shrink an article to no less than this share of its size without a reason.
const MIN_KEEP_PCT: usize = 60;
/// Frontmatter keys every article must carry.
pub(crate) const REQUIRED: [&str; 4] = ["title", "summary", "tags", "updated"];
/// How far back the daily note looks for logs it has not listed yet.
const NEW_SECTION_DAYS: i64 = 7;
/// Excerpt length kept per source in the log.
const EXCERPT_MAX: usize = 1500;

#[derive(Deserialize)]
pub struct Batch {
    pub date: String,
    #[serde(default)]
    pub sources: Vec<Source>,
    #[serde(default)]
    pub ops: Vec<Op>,
}

#[derive(Deserialize)]
pub struct Source {
    pub id: String,
    pub path: String,
    #[serde(default)]
    pub excerpt: String,
}

#[derive(Deserialize)]
pub struct Op {
    /// `create` or `update`
    pub op: String,
    /// vault-relative, e.g. `knowledge/software/infra/litellm-gateway.md`
    pub path: String,
    /// the whole new file, frontmatter included
    pub content: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub sources: Vec<String>,
    /// why a large shrink is intended (a split or a merge); absent = shrink guard applies
    #[serde(default)]
    pub allow_shrink: Option<String>,
}

#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub created: usize,
    pub updated: usize,
    pub rejected: usize,
    pub log: PathBuf,
}

/// `---`-fenced `key: value` frontmatter at the very top of `content`. Values are raw strings.
pub(crate) fn frontmatter(content: &str) -> Option<BTreeMap<String, String>> {
    let rest = content.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    let mut out = BTreeMap::new();
    for line in rest[..end].lines() {
        if let Some((k, v)) = line.split_once(':') {
            if !k.starts_with(' ') && !k.is_empty() {
                out.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    Some(out)
}

pub fn log_path(p: &Profile, date: NaiveDate) -> PathBuf {
    p.knowledge
        .join(LOG_DIR)
        .join(date.format("%Y").to_string())
        .join(date.format("%m").to_string())
        .join(format!("{}.md", date.format("%Y-%m-%d")))
}

/// The tag vocabulary: every backticked word in the template's `## Tags` section, plus the last
/// segment of each registered domain. The vault's SCHEMA.md is generated from the same two, so
/// it is not read back.
pub(crate) fn tag_vocab(reg: Option<&Registry>) -> HashSet<String> {
    let lines = md::section_lines(SCHEMA_TEMPLATE, "Tags").unwrap_or_default();
    let mut out = HashSet::new();
    for line in lines {
        for (i, part) in line.split('`').enumerate() {
            if i % 2 == 1 && !part.is_empty() {
                out.insert(part.to_string());
            }
        }
    }
    out.extend(reg.into_iter().flat_map(|r| r.leaves()).map(str::to_string));
    out
}

/// True when a file stem carries a date (`YYYY-MM`, so `YYYY-MM-DD` too) as its own segment: a
/// day's diary, not a topic. `cve-2024-12345` is a topic: its digits run on past the month.
pub(crate) fn dated(stem: &str) -> bool {
    let b = stem.as_bytes();
    let edge = |i: usize| b.get(i).is_none_or(|c| matches!(c, b'-' | b'_'));
    (0..b.len().saturating_sub(6)).any(|i| {
        let w = &b[i..i + 7];
        (i == 0 || edge(i - 1))
            && edge(i + 7)
            && w[..4].iter().all(u8::is_ascii_digit)
            && (w[..2] == *b"19" || w[..2] == *b"20")
            && w[4] == b'-'
            && matches!((w[5], w[6]), (b'0', b'1'..=b'9') | (b'1', b'0'..=b'2'))
    })
}

/// A title or slug reduced to its lowercase words, so `Release process` and `release-process`
/// compare equal.
pub(crate) fn normalize(s: &str) -> String {
    s.to_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The article's title: frontmatter `title`, else its file stem.
pub(crate) fn title_of(file: &Path, content: &str) -> String {
    frontmatter(content)
        .and_then(|fm| fm.get("title").cloned())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| {
            file.file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
        })
}

/// The topics core already covers: every core page's title and slug (a hub's `index` slug
/// aside), normalized. A project page with one of these titles restates core.
pub(crate) fn core_topics(p: &Profile, reg: &Registry) -> HashSet<String> {
    let mut out = HashSet::new();
    for f in articles(p) {
        if !reg
            .find(&p.knowledge, &f)
            .is_some_and(|d| d.kind() == Kind::Core)
        {
            continue;
        }
        let content = fs::read_to_string(&f).unwrap_or_default();
        out.insert(normalize(&title_of(&f, &content)));
        let stem = f.file_stem().unwrap_or_default().to_string_lossy();
        if stem != "index" {
            out.insert(normalize(&stem));
        }
    }
    out
}

/// Why a page breaks its domain's kind rule, if it does: a core page that links none of the
/// domain's canonical docs, or a project page titled like a core topic.
pub(crate) fn kind_violation(
    d: &Domain,
    title: &str,
    content: &str,
    core: &HashSet<String>,
) -> Option<String> {
    match d.kind() {
        Kind::Core
            if !d.canonical.is_empty() && !d.canonical.iter().any(|c| content.contains(c)) =>
        {
            Some(format!(
                "a `{}` page links none of its canonical docs ({})",
                d.id,
                d.canonical.join(", ")
            ))
        }
        Kind::Project if core.contains(&normalize(title)) => Some(format!(
            "restates the core topic `{title}`: link the core hub instead"
        )),
        _ => None,
    }
}

/// A source path in the vault (the rest are named by absolute or `~` path).
fn in_vault(path: &str) -> bool {
    !path.starts_with('/') && !path.starts_with('~')
}

/// A `sources` entry or source path as one comparable form: no brackets, quotes or `.md`.
fn source_key(s: &str) -> String {
    let t = s.trim().trim_matches('"').trim_start_matches("[[");
    let t = t.trim_end_matches("]]");
    t.strip_suffix(".md").unwrap_or(t).to_string()
}

pub(crate) fn list_tags(raw: &str) -> Vec<String> {
    raw.trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Every article under `knowledge/`: markdown, outside `_log/`, not the schema.
pub(crate) fn articles(p: &Profile) -> Vec<PathBuf> {
    fn walk(dir: &Path, skip: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let path = e.path();
            let hidden = e.file_name().to_string_lossy().starts_with('.');
            if hidden || path == skip {
                continue;
            }
            match e.file_type() {
                Ok(t) if t.is_dir() => walk(&path, skip, out),
                Ok(_) if path.extension().and_then(|x| x.to_str()) == Some("md") => out.push(path),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    walk(&p.knowledge, &p.knowledge.join(LOG_DIR), &mut out);
    let generated = [p.knowledge.join(SCHEMA_FILE), p.knowledge.join(README_FILE)];
    out.retain(|f| !generated.contains(f));
    out.sort();
    out
}

/// The schema: the built-in template with the vault's registry in its `## Domains` section.
pub fn schema(reg: Option<&Registry>) -> String {
    SCHEMA_TEMPLATE.replace("{{domains}}", &registry::render(reg))
}

/// Regenerate `knowledge/SCHEMA.md` from the template and the registry. Returns the file.
pub fn write_schema(p: &Profile) -> Result<PathBuf> {
    let file = p.knowledge.join(SCHEMA_FILE);
    let reg = registry::load(p)?;
    fs::create_dir_all(&p.knowledge)?;
    md::write_atomic(&file, &schema(reg.as_ref()))?;
    Ok(file)
}

/// The health line: articles, lint drift per class, the last compiled log, and whether retired
/// names were checked (only `apply` has the retired list; `init` and `domain add` do not).
fn health(p: &Profile, gone: &List, today: NaiveDate) -> Result<String> {
    let r = crate::knowledge_lint::lint(p, gone)?;
    let drift: Vec<String> = r
        .classes
        .iter()
        .filter(|(_, v)| !v.is_empty())
        .map(|(c, v)| format!("{c} {}", v.len()))
        .collect();
    let lint = match drift.is_empty() {
        true => "lint 0".to_string(),
        false => format!("lint {} ({})", r.total(), drift.join(", ")),
    };
    let compiled = match last_log_date(p) {
        Some(d) => format!(
            "last compiled [[{}]]",
            config::wikilink(&p.root, &log_path(p, d))
        ),
        None => "nothing compiled yet".to_string(),
    };
    let retired = match gone.is_empty() {
        true => ", retired names not checked",
        false => "",
    };
    Ok(format!(
        "- {today}: {} articles, {lint}{retired}, {compiled}.",
        r.articles
    ))
}

/// Regenerate `knowledge/README.md`, the hub's front door: the template, the registry's domain
/// index and the health line. Returns the file.
pub fn write_readme(p: &Profile, gone: &List, today: NaiveDate) -> Result<PathBuf> {
    let file = p.knowledge.join(README_FILE);
    let reg = registry::load(p)?;
    let text = README_TEMPLATE
        .replace("{{domains}}", &registry::index(reg.as_ref()))
        .replace("{{health}}", &health(p, gone, today)?);
    fs::create_dir_all(&p.knowledge)?;
    md::write_atomic(&file, &text)?;
    Ok(file)
}

/// Write `knowledge/SCHEMA.md` and `knowledge/README.md`. Refuses to overwrite the schema unless
/// `force`; the README is always regenerated.
pub fn init(p: &Profile, log: &Logger, force: bool) -> Result<()> {
    let file = p.knowledge.join(SCHEMA_FILE);
    if file.exists() && !force {
        println!("{} exists (use --force to rewrite it)", file.display());
    } else {
        write_schema(p)?;
        log.info("knowledge", &format!("wrote {}", file.display()));
        println!("{}", file.display());
    }
    let today = chrono::Local::now().date_naive();
    println!("{}", write_readme(p, &List::default(), today)?.display());
    Ok(())
}

/// The `n` articles that most need a whole-article review: oldest `reviewed` first, a missing
/// one counting as oldest, ties by path. Vault-relative paths.
pub fn due(p: &Profile, n: usize) -> Vec<String> {
    let mut rows: Vec<(String, PathBuf)> = articles(p)
        .into_iter()
        .map(|f| {
            let reviewed = fs::read_to_string(&f)
                .ok()
                .and_then(|c| frontmatter(&c))
                .and_then(|fm| fm.get("reviewed").cloned())
                .unwrap_or_default();
            (reviewed, f)
        })
        .collect();
    rows.sort();
    rows.into_iter()
        .take(n)
        .map(|(_, f)| format!("{}.md", config::wikilink(&p.root, &f)))
        .collect()
}

/// Where an op may write, or why it may not.
fn target(p: &Profile, rel: &str) -> Result<PathBuf, String> {
    let rel_path = Path::new(rel);
    if !rel_path
        .components()
        .all(|c| matches!(c, Component::Normal(_)))
    {
        return Err("path must be vault-relative with no `..`".into());
    }
    let file = p.root.join(rel_path);
    if !file.starts_with(&p.knowledge) {
        return Err("path is outside knowledge/".into());
    }
    if file.starts_with(p.knowledge.join(LOG_DIR)) {
        return Err("knowledge/_log/ is written by apply only".into());
    }
    if file == p.knowledge.join(SCHEMA_FILE) {
        return Err("the schema is written by `notes knowledge init` only".into());
    }
    if file == p.knowledge.join(README_FILE) {
        return Err("the README is generated by `notes knowledge` only".into());
    }
    if file.extension().and_then(|x| x.to_str()) != Some("md") {
        return Err("only .md files".into());
    }
    Ok(file)
}

fn mtime_secs(f: &Path) -> Option<i64> {
    let t = fs::metadata(f).ok()?.modified().ok()?;
    let d = t.duration_since(std::time::UNIX_EPOCH).ok()?;
    Some(d.as_secs() as i64)
}

/// What every op in one batch is checked against, read once per batch.
struct Rules<'a> {
    vocab: HashSet<String>,
    registry: Option<Registry>,
    core: HashSet<String>,
    /// source id -> path, for the batch's sources
    sources: BTreeMap<String, String>,
    retired: &'a List,
}

/// Check one op against the vault as it stands. Ok = the file to write; Err = why not.
fn check(
    p: &Profile,
    op: &Op,
    started: Option<i64>,
    rules: &Rules<'_>,
    warnings: &mut Vec<String>,
) -> Result<PathBuf, String> {
    let file = target(p, &op.path)?;
    let Some(fm) = frontmatter(&op.content) else {
        return Err("content has no frontmatter".into());
    };
    let missing: Vec<&str> = REQUIRED
        .iter()
        .copied()
        .filter(|k| fm.get(*k).is_none_or(|v| v.is_empty() || v == "[]"))
        .collect();
    if !missing.is_empty() {
        return Err(format!("frontmatter is missing {}", missing.join(", ")));
    }
    let unknown: Vec<String> = list_tags(&fm["tags"])
        .into_iter()
        .filter(|t| !rules.vocab.contains(t))
        .map(|t| format!("`{t}`"))
        .collect();
    if !unknown.is_empty() {
        return Err(format!("tag {} is not in the schema", unknown.join(", ")));
    }
    let domain = rules
        .registry
        .as_ref()
        .and_then(|r| r.find(&p.knowledge, &file));
    let unregistered = rules.registry.is_some() && domain.is_none();
    match op.op.as_str() {
        "create" => {
            if file.exists() {
                return Err("create on a file that exists (use update)".into());
            }
            if unregistered {
                return Err(
                    "not under a registered domain (knowledge/domains.toml); register one with `notes knowledge domain add`"
                        .into(),
                );
            }
            if dated(&file.file_stem().unwrap_or_default().to_string_lossy()) {
                return Err(
                    "the slug carries a date: name the topic, and put the date in the body".into(),
                );
            }
        }
        "update" => {
            if !file.exists() {
                return Err("update on a file that does not exist (use create)".into());
            }
            if let (Some(start), Some(m)) = (started, mtime_secs(&file)) {
                if m > start {
                    return Err("the file changed while the engine was running".into());
                }
            }
            let old = fs::metadata(&file).map(|m| m.len() as usize).unwrap_or(0);
            if op.content.len() * 100 < old * MIN_KEEP_PCT && op.allow_shrink.is_none() {
                return Err(format!(
                    "shrinks the article from {old} to {} bytes with no allow_shrink reason",
                    op.content.len()
                ));
            }
            // A page from before the registry is still updated in place, so its facts keep
            // landing; `notes knowledge lint` counts it until it moves.
            if unregistered {
                warnings.push(format!("`{}`: not under a registered domain", op.path));
            }
        }
        other => return Err(format!("unknown op `{other}`")),
    }
    if let Some(why) =
        domain.and_then(|d| kind_violation(d, &fm["title"], &op.content, &rules.core))
    {
        return Err(why);
    }
    let listed: HashSet<String> = fm
        .get("sources")
        .map(|s| list_tags(s).iter().map(|e| source_key(e)).collect())
        .unwrap_or_default();
    let unlisted: Vec<&str> = op
        .sources
        .iter()
        .filter_map(|id| rules.sources.get(id))
        .filter(|path| in_vault(path) && !listed.contains(&source_key(path)))
        .map(String::as_str)
        .collect();
    if !unlisted.is_empty() {
        return Err(format!(
            "frontmatter `sources` does not list {}",
            unlisted.join(", ")
        ));
    }
    // A stale line the page already had is lint's to count; a write may not add one.
    let old = if op.op == "update" {
        fs::read_to_string(&file).unwrap_or_default()
    } else {
        String::new()
    };
    if let Some(h) = rules.retired.added(&old, &op.content).first() {
        return Err(format!(
            "line {} names `{}` as live, but it {}: say on that line that it is sold, retired or replaced, or drop the claim",
            h.line, h.retired.name, h.retired.why
        ));
    }
    Ok(file)
}

fn source_heading(p: &Profile, s: &Source) -> String {
    if in_vault(&s.path) {
        let link = s.path.strip_suffix(".md").unwrap_or(&s.path);
        format!("### {}: [[{link}]]", s.id)
    } else {
        // Outside the vault (a session wind-down): name it, and the excerpt below is the copy.
        let _ = p;
        format!("### {}: `{}`", s.id, s.path)
    }
}

fn excerpt(s: &str) -> String {
    let mut cut: String = s.chars().take(EXCERPT_MAX).collect();
    if cut.len() < s.len() {
        cut.push_str(" ...");
    }
    cut.lines()
        .map(|l| format!("> {l}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Apply a batch (see the module doc). Rejected ops are recorded, not fatal; a malformed batch,
/// an already-logged date or a batch over `MAX_OPS` is refused whole.
pub fn apply(
    p: &Profile,
    log: &Logger,
    batch_file: &Path,
    started: Option<i64>,
    dry_run: bool,
    retired: &List,
) -> Result<Outcome> {
    let raw = fs::read_to_string(batch_file)
        .with_context(|| format!("reading {}", batch_file.display()))?;
    let batch: Batch = serde_json::from_str(&raw).context("parsing the ops batch")?;
    let date = NaiveDate::parse_from_str(&batch.date, "%Y-%m-%d")
        .with_context(|| format!("batch date `{}` is not YYYY-MM-DD", batch.date))?;
    let log_file = log_path(p, date);
    if log_file.exists() {
        bail!(
            "{} already exists: that date was applied",
            log_file.display()
        );
    }
    if batch.ops.len() > MAX_OPS {
        bail!("{} ops in one batch (max {MAX_OPS})", batch.ops.len());
    }

    let reg = registry::load(p)?;
    let rules = Rules {
        vocab: tag_vocab(reg.as_ref()),
        core: reg.as_ref().map(|r| core_topics(p, r)).unwrap_or_default(),
        sources: batch
            .sources
            .iter()
            .map(|s| (s.id.clone(), s.path.clone()))
            .collect(),
        registry: reg,
        retired,
    };
    let mut warnings = Vec::new();
    let mut seen = HashSet::new();
    let mut changes = Vec::new();
    let mut out = Outcome {
        log: log_file.clone(),
        ..Default::default()
    };

    for op in &batch.ops {
        let verdict = if seen.insert(op.path.clone()) {
            check(p, op, started, &rules, &mut warnings)
        } else {
            Err("a second op on the same path in one batch".into())
        };
        let file = match verdict {
            Ok(f) => f,
            Err(why) => {
                out.rejected += 1;
                eprintln!("rejected {}: {why}", op.path);
                changes.push(format!("- rejected `{}`: {why}", op.path));
                continue;
            }
        };
        for id in op
            .sources
            .iter()
            .filter(|id| !rules.sources.contains_key(*id))
        {
            warnings.push(format!("`{}`: cites unknown source `{id}`", op.path));
        }
        let link = config::wikilink(&p.root, &file);
        let verb = if op.op == "create" {
            "created"
        } else {
            "updated"
        };
        let cites = if op.sources.is_empty() {
            String::new()
        } else {
            format!(" ({})", op.sources.join(", "))
        };
        changes.push(format!("- {verb} [[{link}]]: {}{cites}", op.reason.trim()));
        if op.op == "create" {
            out.created += 1;
        } else {
            out.updated += 1;
        }
        if dry_run {
            continue;
        }
        if op.op == "update" {
            snapshot_original(p, &file)?;
        }
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
        md::write_atomic(&file, &op.content)?;
    }

    let mut s = format!(
        "---\ndate: {d}\ntags: [knowledge-log]\n---\n\n# Knowledge log {d}\n\n## Changes\n",
        d = batch.date
    );
    if changes.is_empty() {
        s.push_str("- none: nothing in the sources was worth keeping\n");
    }
    for c in &changes {
        s.push_str(c);
        s.push('\n');
    }
    if !warnings.is_empty() {
        s.push_str("\n## Warnings\n");
        for w in &warnings {
            s.push_str(&format!("- {w}\n"));
        }
    }
    s.push_str("\n## Sources\n");
    for src in &batch.sources {
        s.push_str(&format!("\n{}\n", source_heading(p, src)));
        if !src.excerpt.trim().is_empty() {
            s.push_str(&format!("{}\n", excerpt(src.excerpt.trim())));
        }
    }

    if dry_run {
        print!("{s}");
    } else {
        fs::create_dir_all(log_file.parent().unwrap())?;
        md::write_atomic(&log_file, &s)?;
        write_readme(p, retired, chrono::Local::now().date_naive())?;
        log.info(
            "knowledge",
            &format!(
                "{}: created {} updated {} rejected {}",
                batch.date, out.created, out.updated, out.rejected
            ),
        );
    }
    println!(
        "created {} updated {} rejected {} -> {}",
        out.created,
        out.updated,
        out.rejected,
        log_file.display()
    );
    Ok(out)
}

/// The first time the engine rewrites an article it did not write (no `sources:` key), keep the
/// human's version beside the logs. Once only: later versions are the engine's and git has them.
fn snapshot_original(p: &Profile, file: &Path) -> Result<()> {
    let old = fs::read_to_string(file)?;
    if frontmatter(&old).is_some_and(|fm| fm.contains_key("sources")) {
        return Ok(());
    }
    let rel = file.strip_prefix(&p.knowledge).unwrap_or(file);
    let copy = p.knowledge.join(LOG_DIR).join("originals").join(rel);
    if copy.exists() {
        return Ok(());
    }
    fs::create_dir_all(copy.parent().unwrap())?;
    fs::write(&copy, old)?;
    Ok(())
}

/// The knowledge line of the daily note's `## Morning`: ONE line counting the articles created
/// and updated by every log from the last week newer than the newest log the previous note links,
/// linking the newest of them. The articles themselves are in that log and the knowledge MOC (a
/// footer link), so listing them here repeated both; it ran to 18 lines after a three-log week.
///
/// Keyed on a DATE read from the previous note, not on the previous note containing each link:
/// the "nothing new" line links the last log too, so a quiet day still carries the key forward
/// and a log listed two notes ago is not listed again.
pub fn morning_lines(p: &Profile, prev_note: Option<&str>, today: NaiveDate) -> String {
    let listed = prev_note.and_then(newest_linked_log);
    let (mut created, mut updated) = (0, 0);
    let mut span: Option<(NaiveDate, NaiveDate)> = None;
    for back in (1..=NEW_SECTION_DAYS).rev() {
        let date = today - Duration::days(back);
        if listed.is_some_and(|l| date <= l) {
            continue;
        }
        let Ok(content) = fs::read_to_string(log_path(p, date)) else {
            continue;
        };
        let lines = md::section_lines(&content, "Changes").unwrap_or_default();
        let c = lines
            .iter()
            .filter(|l| l.starts_with("- created [["))
            .count();
        let u = lines
            .iter()
            .filter(|l| l.starts_with("- updated [["))
            .count();
        if c + u == 0 {
            continue;
        }
        created += c;
        updated += u;
        span = Some((span.map_or(date, |(first, _)| first), date));
    }
    let link = |d: NaiveDate| config::wikilink(&p.root, &log_path(p, d));
    match (span, last_log_date(p)) {
        (Some((first, last)), _) => {
            let when = if first == last {
                format!("{last}")
            } else {
                format!("{first} to {last}")
            };
            format!(
                "- Knowledge: {created} new, {updated} updated ({when}) [[{}]]\n",
                link(last)
            )
        }
        (None, Some(d)) => format!("- Knowledge: nothing new (last compiled [[{}]])\n", link(d)),
        (None, None) => "- Knowledge: nothing compiled yet\n".to_string(),
    }
}

/// The date of the newest knowledge log a note links (`[[.../_log/YYYY/MM/YYYY-MM-DD]]`).
fn newest_linked_log(note: &str) -> Option<NaiveDate> {
    note.split("[[")
        .skip(1)
        .filter_map(|r| r.split("]]").next())
        .filter(|t| t.contains(&format!("{LOG_DIR}/")))
        .filter_map(|t| NaiveDate::parse_from_str(t.rsplit('/').next()?, "%Y-%m-%d").ok())
        .max()
}

/// The newest date with a log under `knowledge/_log/YYYY/MM/`, if any.
fn last_log_date(p: &Profile) -> Option<NaiveDate> {
    let mut newest = None;
    let years = fs::read_dir(p.knowledge.join(LOG_DIR)).ok()?;
    for y in years.flatten().filter(|e| e.path().is_dir()) {
        for m in fs::read_dir(y.path()).into_iter().flatten().flatten() {
            for f in fs::read_dir(m.path()).into_iter().flatten().flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                if let Some(Ok(d)) = name
                    .strip_suffix(".md")
                    .map(|stem| NaiveDate::parse_from_str(stem, "%Y-%m-%d"))
                {
                    newest = newest.max(Some(d));
                }
            }
        }
    }
    newest
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("notes-knowledge-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("knowledge")).unwrap();
        dir
    }

    fn profile(root: &Path) -> Profile {
        config::test_profile(root.to_str().unwrap())
    }

    fn logger(root: &Path) -> Logger {
        Logger::new(root.join(".state/journal.log"), false)
    }

    fn article(title: &str, body: &str) -> String {
        format!(
            "---\ntitle: {title}\nsummary: what {title} is\ntags: [software, reference]\nupdated: 2026-10-13\nsources: [journal/daily/2026-10-13.md]\n---\n\n# {title}\n\n{body}\n"
        )
    }

    fn batch(root: &Path, json: &str) -> PathBuf {
        let f = root.join("ops.json");
        fs::write(&f, json).unwrap();
        f
    }

    fn op(kind: &str, path: &str, content: &str) -> String {
        format!(
            r#"{{"op":"{kind}","path":"{path}","content":{},"reason":"r","sources":["s1"]}}"#,
            serde_json_string(content)
        )
    }

    fn serde_json_string(s: &str) -> String {
        serde_json::to_string(s).unwrap()
    }

    fn run(root: &Path, ops: &[String]) -> Result<Outcome> {
        let json = format!(
            r#"{{"date":"2026-10-13","sources":[{{"id":"s1","path":"journal/daily/2026-10-13.md","excerpt":"a fact"}}],"ops":[{}]}}"#,
            ops.join(",")
        );
        let f = batch(root, &json);
        apply(
            &profile(root),
            &logger(root),
            &f,
            None,
            false,
            &List::default(),
        )
    }

    #[test]
    fn create_writes_the_article_and_the_log() {
        let root = vault("create");
        let out = run(
            &root,
            &[op(
                "create",
                "knowledge/software/gw.md",
                &article("gw", "body"),
            )],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 0));
        assert!(root.join("knowledge/software/gw.md").exists());
        let log = fs::read_to_string(root.join("knowledge/_log/2026/10/2026-10-13.md")).unwrap();
        assert!(
            log.contains("- created [[knowledge/software/gw]]: r (s1)"),
            "{log}"
        );
        assert!(
            log.contains("### s1: [[journal/daily/2026-10-13]]\n> a fact"),
            "{log}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_op_that_adds_a_live_line_about_a_retired_host_is_rejected_and_one_that_says_sold_is_not()
    {
        let root = vault("retired");
        let gone =
            crate::knowledge_retired::parse("host\tmac-studio\tleft the home-config inventory\n")
                .unwrap();
        let day = |d: &str, ops: &[String]| {
            let f = batch(
                &root,
                &format!(
                    r#"{{"date":"{d}","sources":[{{"id":"s1","path":"journal/daily/2026-10-13.md"}}],"ops":[{}]}}"#,
                    ops.join(",")
                ),
            );
            apply(&profile(&root), &logger(&root), &f, None, false, &gone).unwrap()
        };
        let live = op(
            "create",
            "knowledge/software/llm.md",
            &article("llm", "MLX runs on the Mac Studio."),
        );
        let out = day("2026-10-13", std::slice::from_ref(&live));
        assert_eq!((out.created, out.rejected), (0, 1));
        let log = fs::read_to_string(root.join("knowledge/_log/2026/10/2026-10-13.md")).unwrap();
        assert!(
            log.contains(
                "line 11 names `mac-studio` as live, but it left the home-config inventory"
            ),
            "{log}"
        );
        // Negative control: the same page saying the host was sold applies.
        let sold = op(
            "create",
            "knowledge/software/llm.md",
            &article("llm", "MLX ran on the Mac Studio until it was sold."),
        );
        assert_eq!(day("2026-10-14", &[sold]).created, 1);
        // A stale line already on the page does not block an update that leaves it alone.
        fs::write(
            root.join("knowledge/software/llm.md"),
            article("llm", "MLX runs on the Mac Studio."),
        )
        .unwrap();
        let more = op(
            "update",
            "knowledge/software/llm.md",
            &article("llm", "MLX runs on the Mac Studio.\nA new fact."),
        );
        assert_eq!(day("2026-10-15", &[more]).updated, 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_date_is_applied_once() {
        let root = vault("once");
        run(&root, &[]).unwrap();
        let err = run(&root, &[]).unwrap_err().to_string();
        assert!(err.contains("already exists"), "{err}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn writes_outside_the_articles_are_rejected() {
        let root = vault("paths");
        let a = article("x", "b");
        let out = run(
            &root,
            &[
                op("create", "knowledge/../journal/x.md", &a),
                op("create", "journal/daily/x.md", &a),
                op("create", "knowledge/_log/2026/10/x.md", &a),
                op("create", "knowledge/SCHEMA.md", &a),
                op("create", "knowledge/README.md", &a),
                op("create", "knowledge/x.txt", &a),
                op("create", "/etc/x.md", &a),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (0, 7));
        assert!(rejections(&out).contains("the README is generated"));
        assert!(!root.join("journal").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn frontmatter_is_required() {
        let root = vault("fm");
        let out = run(
            &root,
            &[
                op("create", "knowledge/a.md", "# no frontmatter\n"),
                op("create", "knowledge/b.md", "---\ntitle: b\n---\n# b\n"),
            ],
        )
        .unwrap();
        assert_eq!(out.rejected, 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn create_and_update_must_match_the_file() {
        let root = vault("verbs");
        fs::write(root.join("knowledge/old.md"), article("old", "b")).unwrap();
        let out = run(
            &root,
            &[
                op("create", "knowledge/old.md", &article("old", "b2")),
                op("update", "knowledge/new.md", &article("new", "b")),
            ],
        )
        .unwrap();
        assert_eq!(out.rejected, 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_update_may_not_gut_an_article_without_a_reason() {
        let root = vault("shrink");
        let long = article("big", &"a sentence worth keeping. ".repeat(40));
        fs::write(root.join("knowledge/big.md"), &long).unwrap();
        let out = run(
            &root,
            &[op("update", "knowledge/big.md", &article("big", "x"))],
        )
        .unwrap();
        assert_eq!(out.rejected, 1);
        assert_eq!(
            fs::read_to_string(root.join("knowledge/big.md")).unwrap(),
            long
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_update_loses_to_a_human_edit_made_during_the_run() {
        let root = vault("race");
        fs::write(root.join("knowledge/a.md"), article("a", "human")).unwrap();
        let f = batch(
            &root,
            &format!(
                r#"{{"date":"2026-10-13","ops":[{}]}}"#,
                op("update", "knowledge/a.md", &article("a", "engine"))
            ),
        );
        // The engine started a minute before the human's save.
        let started = mtime_secs(&root.join("knowledge/a.md")).unwrap() - 60;
        let out = apply(
            &profile(&root),
            &logger(&root),
            &f,
            Some(started),
            false,
            &List::default(),
        )
        .unwrap();
        assert_eq!(out.rejected, 1);
        assert!(fs::read_to_string(root.join("knowledge/a.md"))
            .unwrap()
            .contains("human"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_hand_written_article_is_snapshotted_once() {
        let root = vault("orig");
        fs::write(root.join("knowledge/mine.md"), "# mine\n\nhand written\n").unwrap();
        run(
            &root,
            &[op(
                "update",
                "knowledge/mine.md",
                &article("mine", "hand written, compiled"),
            )],
        )
        .unwrap();
        let copy = root.join("knowledge/_log/originals/mine.md");
        assert_eq!(
            fs::read_to_string(&copy).unwrap(),
            "# mine\n\nhand written\n"
        );

        // The second rewrite is of an engine article (it now has `sources:`): no new copy.
        fs::remove_file(&copy).unwrap();
        let f = batch(
            &root,
            &format!(
                r#"{{"date":"2026-10-14","ops":[{}]}}"#,
                op(
                    "update",
                    "knowledge/mine.md",
                    &article("mine", "hand written, compiled again")
                )
            ),
        );
        apply(
            &profile(&root),
            &logger(&root),
            &f,
            None,
            false,
            &List::default(),
        )
        .unwrap();
        assert!(!copy.exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn too_many_ops_refuses_the_whole_batch() {
        let root = vault("cap");
        let ops: Vec<String> = (0..=MAX_OPS)
            .map(|i| op("create", &format!("knowledge/n{i}.md"), &article("n", "b")))
            .collect();
        assert!(run(&root, &ops).is_err());
        assert!(!root.join("knowledge/_log").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dry_run_writes_nothing() {
        let root = vault("dry");
        let json = format!(
            r#"{{"date":"2026-10-13","ops":[{}]}}"#,
            op("create", "knowledge/a.md", &article("a", "b"))
        );
        let f = batch(&root, &json);
        let out = apply(
            &profile(&root),
            &logger(&root),
            &f,
            None,
            true,
            &List::default(),
        )
        .unwrap();
        assert_eq!(out.created, 1);
        assert!(!root.join("knowledge/a.md").exists());
        assert!(!out.log.exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn due_puts_never_reviewed_first_and_skips_logs_and_schema() {
        let root = vault("due");
        let k = root.join("knowledge");
        fs::write(k.join("SCHEMA.md"), SCHEMA_TEMPLATE).unwrap();
        fs::create_dir_all(k.join("_log/2026/10")).unwrap();
        fs::write(k.join("_log/2026/10/2026-10-13.md"), "x").unwrap();
        fs::write(
            k.join("old.md"),
            "---\ntitle: o\nreviewed: 2026-01-01\n---\n",
        )
        .unwrap();
        fs::write(
            k.join("new.md"),
            "---\ntitle: n\nreviewed: 2026-10-01\n---\n",
        )
        .unwrap();
        fs::write(k.join("never.md"), "# never\n").unwrap();
        assert_eq!(
            due(&profile(&root), 5),
            vec!["knowledge/never.md", "knowledge/old.md", "knowledge/new.md"]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unknown_tag_is_refused() {
        let root = vault("tags");
        let a = article("a", "b").replace("[software, reference]", "[software, madeup]");
        let out = run(
            &root,
            &[
                op("create", "knowledge/a.md", &a),
                // Negative control: the same op with schema tags applies.
                op("create", "knowledge/b.md", &article("b", "b")),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 1));
        assert!(!root.join("knowledge/a.md").exists());
        let log = fs::read_to_string(&out.log).unwrap();
        assert!(log.contains("tag `madeup` is not in the schema"), "{log}");
        let _ = fs::remove_dir_all(&root);
    }

    const REGISTRY: &str = "[[domain]]\nid = \"core/ops\"\nis = \"how we ship\"\ncanonical = [\"LSD/release.md\"]\n\n[[domain]]\nid = \"subjects/software\"\nis = \"software\"\n\n[[domain]]\nid = \"projects/trader\"\nis = \"the bot\"\n";

    fn registered(name: &str) -> PathBuf {
        let root = vault(name);
        fs::write(root.join("knowledge/domains.toml"), REGISTRY).unwrap();
        root
    }

    fn rejections(out: &Outcome) -> String {
        md::section_lines(&fs::read_to_string(&out.log).unwrap(), "Changes")
            .unwrap_or_default()
            .join("\n")
    }

    #[test]
    fn a_new_page_outside_the_registry_is_refused() {
        let root = registered("outside");
        let out = run(
            &root,
            &[
                op("create", "knowledge/software/gw.md", &article("gw", "b")),
                op("create", "knowledge/core/x.md", &article("x", "b")),
                // Negative control: the same page under a registered domain applies.
                op(
                    "create",
                    "knowledge/subjects/software/gw.md",
                    &article("gw", "b"),
                ),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 2), "{}", rejections(&out));
        assert!(rejections(&out).contains("not under a registered domain"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_page_from_before_the_registry_is_still_updated_with_a_warning() {
        let root = registered("legacy");
        fs::create_dir_all(root.join("knowledge/software")).unwrap();
        fs::write(root.join("knowledge/software/old.md"), article("old", "b")).unwrap();
        let out = run(
            &root,
            &[op(
                "update",
                "knowledge/software/old.md",
                &article("old", "b and more"),
            )],
        )
        .unwrap();
        assert_eq!(out.updated, 1);
        let log = fs::read_to_string(&out.log).unwrap();
        assert!(
            log.contains("`knowledge/software/old.md`: not under a registered domain"),
            "{log}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_dated_slug_is_refused() {
        let root = registered("dated");
        let out = run(
            &root,
            &[
                op(
                    "create",
                    "knowledge/subjects/software/fleet-gotchas-2026-11-09.md",
                    &article("f", "b"),
                ),
                op(
                    "create",
                    "knowledge/subjects/software/notes-2026-11.md",
                    &article("n", "b"),
                ),
                // Negative control: a number that is not a date is a fine slug.
                op(
                    "create",
                    "knowledge/subjects/software/ubuntu-2404.md",
                    &article("u", "b"),
                ),
                op(
                    "create",
                    "knowledge/subjects/software/cve-2024-12345.md",
                    &article("c", "b"),
                ),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (2, 2), "{}", rejections(&out));
        assert!(rejections(&out).contains("the slug carries a date"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_core_page_must_link_its_canonical_doc() {
        let root = registered("canon");
        let out = run(
            &root,
            &[
                op(
                    "create",
                    "knowledge/core/ops/tags.md",
                    &article("tags", "no link"),
                ),
                op(
                    "create",
                    "knowledge/core/ops/steam.md",
                    &article("steam", "see LSD/release.md"),
                ),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 1), "{}", rejections(&out));
        assert!(rejections(&out).contains("links none of its canonical docs (LSD/release.md)"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_project_page_titled_like_a_core_topic_is_refused() {
        let root = registered("restate");
        fs::create_dir_all(root.join("knowledge/core/ops")).unwrap();
        fs::write(
            root.join("knowledge/core/ops/release-process.md"),
            article("Release process", "LSD/release.md"),
        )
        .unwrap();
        let out = run(
            &root,
            &[
                op(
                    "create",
                    "knowledge/projects/trader/release.md",
                    &article("release-process", "b"),
                ),
                op(
                    "create",
                    "knowledge/projects/trader/risk.md",
                    &article("Risk rules", "b"),
                ),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 1), "{}", rejections(&out));
        assert!(rejections(&out).contains("restates the core topic"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_cited_vault_source_must_be_listed_in_sources() {
        let root = vault("srcs");
        let dates_only = article("a", "b").replace("[journal/daily/2026-10-13.md]", "[2026-10-13]");
        let out = run(
            &root,
            &[
                op("create", "knowledge/a.md", &dates_only),
                op("create", "knowledge/b.md", &article("b", "b")),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 1), "{}", rejections(&out));
        assert!(rejections(&out).contains("`sources` does not list journal/daily/2026-10-13.md"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn domain_add_registers_writes_the_hub_and_the_schema_then_gates_apply() {
        let root = vault("add");
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        let d = |id: &str, aliases: &[&str]| Domain {
            id: id.into(),
            is: "what belongs here".into(),
            aliases: aliases.iter().map(|s| s.to_string()).collect(),
            canonical: vec!["LSD/ci.md".into()],
        };
        registry::add(&p, &logger(&root), d("core/ops", &["release"]), today).unwrap();
        registry::add(&p, &logger(&root), d("subjects/biology", &[]), today).unwrap();
        // A name another domain has is refused, and nothing is written.
        let before = fs::read_to_string(registry::path(&p)).unwrap();
        assert!(registry::add(&p, &logger(&root), d("subjects/release", &[]), today).is_err());
        assert_eq!(fs::read_to_string(registry::path(&p)).unwrap(), before);

        let reg = registry::load(&p).unwrap().unwrap();
        assert_eq!(reg.domain.len(), 2);
        let hub = fs::read_to_string(root.join("knowledge/core/ops/index.md")).unwrap();
        assert!(hub.contains("- `LSD/ci.md`"), "{hub}");
        let schema = fs::read_to_string(root.join("knowledge/SCHEMA.md")).unwrap();
        assert!(
            schema.contains("- `core/ops`: what belongs here Aliases: `release`."),
            "{schema}"
        );
        assert!(!schema.contains("{{domains}}"));
        // The new domain's name is a tag, and its hub passes the rules a write is held to.
        assert!(tag_vocab(Some(&reg)).contains("biology"));
        let compiled = hub.replacen(
            "\n---\n\n",
            "\nsources: [journal/daily/2026-10-13.md]\n---\n\n",
            1,
        ) + "\nA fact from the day.\n";
        let out = run(
            &root,
            &[op("update", "knowledge/core/ops/index.md", &compiled)],
        )
        .unwrap();
        assert_eq!((out.updated, out.rejected), (1, 0), "{}", rejections(&out));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn apply_regenerates_the_readme_with_the_domain_index_and_the_health_line() {
        let root = registered("readme");
        let p = profile(&root);
        let page = "---\ntitle: Linux tips\nsummary: s\ntags: [software, howto]\nupdated: 2026-10-13\nsources: [journal/daily/2026-10-13.md]\n---\n\n# Linux tips\n\nA fact. [[knowledge/nowhere]]\n";
        let out = run(
            &root,
            &[op(
                "create",
                "knowledge/subjects/software/linux-tips.md",
                page,
            )],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (1, 0), "{}", rejections(&out));

        let readme = fs::read_to_string(root.join("knowledge/README.md")).unwrap();
        assert!(!readme.contains("{{"), "{readme}");
        // One heading per kind present, in kind order, each domain linked to its hub.
        let core = readme
            .find("### Core: how we work\n\n- [[knowledge/core/ops/index]]: how we ship\n")
            .expect(&readme);
        let subjects = readme
            .find("- [[knowledge/subjects/software/index]]: software\n")
            .expect(&readme);
        let projects = readme
            .find("- [[knowledge/projects/trader/index]]: the bot\n")
            .expect(&readme);
        assert!(core < subjects && subjects < projects, "{readme}");
        assert!(!readme.contains("### References"), "{readme}");
        // The health line counts what lint counts (the page's dead link), and the README is not
        // one of the articles.
        assert_eq!(
            crate::knowledge_lint::lint(&p, &List::default())
                .unwrap()
                .articles,
            1
        );
        let today = chrono::Local::now().date_naive();
        let health = md::section_lines(&readme, "Health").unwrap().join("\n");
        assert_eq!(
            health,
            format!("- {today}: 1 articles, lint 1 (broken_link 1), retired names not checked, last compiled [[knowledge/_log/2026/10/2026-10-13]].")
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_readme_without_a_registry_says_how_to_start_one() {
        let root = vault("readme-none");
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        write_readme(&p, &List::default(), today).unwrap();
        let readme = fs::read_to_string(root.join("knowledge/README.md")).unwrap();
        assert!(readme.contains("`notes knowledge domain add` writes `knowledge/domains.toml`"));
        assert!(readme.contains(
            "- 2026-11-19: 0 articles, lint 0, retired names not checked, nothing compiled yet."
        ));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_schema_without_a_registry_says_how_to_start_one() {
        let s = schema(None);
        assert!(s.contains("`notes knowledge domain add` writes `knowledge/domains.toml`"));
        assert!(!s.contains("{{domains}}"));
    }

    #[test]
    fn morning_lists_each_log_once_then_says_when_it_last_compiled() {
        let root = vault("morning");
        run(
            &root,
            &[
                op("create", "knowledge/software/gw.md", &article("gw", "b")),
                op("create", "knowledge/x.txt", &article("x", "b")),
            ],
        )
        .unwrap();
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 10, 14).unwrap();

        let lines = morning_lines(&p, Some("# yesterday\n"), today);
        assert_eq!(
            lines,
            "- Knowledge: 1 new, 0 updated (2026-10-13) [[knowledge/_log/2026/10/2026-10-13]]\n"
        );
        // Tomorrow's note sees today's note already listed it, and still links the log.
        let quiet = morning_lines(&p, Some(&lines), today + Duration::days(1));
        assert_eq!(
            quiet,
            "- Knowledge: nothing new (last compiled [[knowledge/_log/2026/10/2026-10-13]])\n"
        );
        // The day after a quiet note, the log is still not listed again.
        assert_eq!(
            morning_lines(&p, Some(&quiet), today + Duration::days(2)),
            quiet
        );
        // A note in the old per-log format is keyed the same way.
        let old = "- Knowledge: [[knowledge/_log/2026/10/2026-10-13]]\n  - new [[knowledge/software/gw]]\n";
        assert_eq!(
            morning_lines(&p, Some(old), today + Duration::days(1)),
            quiet
        );
        assert_eq!(
            morning_lines(&profile(&vault("empty")), None, today),
            "- Knowledge: nothing compiled yet\n"
        );
        let _ = fs::remove_dir_all(&root);
    }
}
