//! `notes knowledge` - the write side of the compiled knowledge base under `knowledge/`.
//!
//! The nightly knowledge engine is a model with READ-only tools. It never writes a file: it
//! hands back a batch of ops as JSON, and `apply` is the one writer. That keeps every guard
//! in tested code instead of in a prompt:
//!
//!   - an op may only touch `knowledge/**/*.md`, never `knowledge/_log/` or the schema;
//!   - a new page goes under a domain of the registry (`knowledge_registry.rs`), with a slug
//!     that names a topic, not a date;
//!   - tags come from the schema, and the vault sources an op cites are in its `sources`;
//!   - a core page links its canonical doc, and a project page never restates a core topic;
//!   - an update loses to a human edit made while the engine was running (`--started`);
//!   - an update may not silently gut an article (the shrink guard);
//!   - a hand-written article is copied to `_log/originals/` the first time it is rewritten;
//!   - every date gets exactly one immutable log, `_log/YYYY/MM/YYYY-MM-DD.md`, which is also
//!     the checkpoint: git syncs it, so no machine re-runs a date another already did.
//!
//! `morning_lines` renders the knowledge half of the daily note's `## Morning` from those logs.

use crate::config::{self, Profile};
use crate::knowledge_gate::{Gate, Item, Kind as GateKind};
use crate::knowledge_registry::{self as registry, Domain, Kind, Registry};
use crate::logging::Logger;
use crate::{knowledge_lint, md, outbox};
use anyhow::{bail, Context, Result};
use chrono::{Duration, NaiveDate};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

const SCHEMA_TEMPLATE: &str = include_str!("knowledge_schema.md");
const SCHEMA_FILE: &str = "SCHEMA.md";
const LOG_DIR: &str = "_log";
/// The log section with one outcome per gated source, which `trace` reads.
const DISPOSITIONS: &str = "Dispositions";
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
    /// For a source no op uses: why nothing in it was kept. The log's Dispositions show it.
    #[serde(default)]
    pub why: String,
}

#[derive(Deserialize)]
pub struct Op {
    /// `create`, `update`, or `domain` (register a domain: `id`, `is`, `aliases`, `canonical`)
    pub op: String,
    /// vault-relative, e.g. `knowledge/software/infra/litellm-gateway.md`
    #[serde(default)]
    pub path: String,
    /// the whole new file, frontmatter included
    #[serde(default)]
    pub content: String,
    /// a `domain` op's id, `is` line, aliases and canonical docs (`knowledge_registry::Domain`)
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub is: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub canonical: Vec<String>,
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
    pub domains: usize,
    /// todo items added to the outbox
    pub routed: usize,
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
    out.retain(|f| f != &p.knowledge.join(SCHEMA_FILE));
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

/// Write `knowledge/SCHEMA.md`. Refuses to overwrite unless `force`.
pub fn init(p: &Profile, log: &Logger, force: bool) -> Result<()> {
    let file = p.knowledge.join(SCHEMA_FILE);
    if file.exists() && !force {
        println!("{} exists (use --force to rewrite it)", file.display());
        return Ok(());
    }
    write_schema(p)?;
    log.info("knowledge", &format!("wrote {}", file.display()));
    println!("{}", file.display());
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
struct Rules {
    vocab: HashSet<String>,
    registry: Option<Registry>,
    core: HashSet<String>,
    /// source id -> path, for the batch's sources
    sources: BTreeMap<String, String>,
}

/// Check one op against the vault as it stands. Ok = the file to write; Err = why not.
fn check(
    p: &Profile,
    op: &Op,
    started: Option<i64>,
    rules: &Rules,
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
    Ok(file)
}

/// A source as the log names it: a wikilink in the vault; outside it (a session wind-down) a
/// backticked path, and the log's excerpt is the copy.
fn source_ref(path: &str) -> String {
    if in_vault(path) {
        format!("[[{}]]", path.strip_suffix(".md").unwrap_or(path))
    } else {
        format!("`{path}`")
    }
}

fn source_heading(s: &Source) -> String {
    format!("### {}: {}", s.id, source_ref(&s.path))
}

/// ` (s1, s2)`: the source ids a Changes line cites, or nothing.
fn cites(ids: &[String]) -> String {
    if ids.is_empty() {
        String::new()
    } else {
        format!(" ({})", ids.join(", "))
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
    gate: Option<&Gate>,
) -> Result<Outcome> {
    let raw = fs::read_to_string(batch_file)
        .with_context(|| format!("reading {}", batch_file.display()))?;
    let batch: Batch = serde_json::from_str(&raw).context("parsing the ops batch")?;
    let date = NaiveDate::parse_from_str(&batch.date, "%Y-%m-%d")
        .with_context(|| format!("batch date `{}` is not YYYY-MM-DD", batch.date))?;
    let log_file = log_path(p, date);
    refuse_batch(&batch, gate, &log_file)?;

    let mut changes = Vec::new();
    let mut out = Outcome {
        log: log_file.clone(),
        ..Default::default()
    };
    // Domains first, so a page in the same batch can land in a domain it registers.
    let mut reg = registry::load(p)?;
    let domain_ops = batch.ops.iter().filter(|o| o.op == "domain");
    for line in apply_domains(p, log, domain_ops, &mut reg, date, dry_run, &mut out)? {
        changes.push(line);
    }

    let rules = Rules {
        vocab: tag_vocab(reg.as_ref()),
        core: reg.as_ref().map(|r| core_topics(p, r)).unwrap_or_default(),
        sources: source_paths(&batch, gate),
        registry: reg,
    };
    let mut warnings = Vec::new();
    let mut seen = HashSet::new();
    // source id -> the pages it went into; the ids whose ops were all refused
    let mut compiled: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut refused: HashSet<String> = HashSet::new();

    for op in batch.ops.iter().filter(|o| o.op != "domain") {
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
                refused.extend(op.sources.iter().cloned());
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
        for id in &op.sources {
            compiled
                .entry(id.clone())
                .or_default()
                .push(format!("[[{link}]]"));
        }
        changes.push(format!(
            "- {verb} [[{link}]]: {}{}",
            op.reason.trim(),
            cites(&op.sources)
        ));
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

    let items = items_of(&batch, gate);
    let compiled = Compiled {
        pages: compiled,
        refused,
        why: reasons(&batch),
    };
    let dispositions = settle(p, log, &items, &compiled, dry_run, &mut out)?;
    let any_read = items.iter().any(|i| i.read.is_some());
    let s = render_log(&batch, &changes, &warnings, &dispositions, any_read);

    if dry_run {
        print!("{s}");
    } else {
        fs::create_dir_all(log_file.parent().unwrap())?;
        md::write_atomic(&log_file, &s)?;
        log.info(
            "knowledge",
            &format!(
                "{}: created {} updated {} rejected {} domains {} routed {}",
                batch.date, out.created, out.updated, out.rejected, out.domains, out.routed
            ),
        );
    }
    println!(
        "created {} updated {} rejected {} domains {} routed {} -> {}",
        out.created,
        out.updated,
        out.rejected,
        out.domains,
        out.routed,
        log_file.display()
    );
    Ok(out)
}

/// Why a batch is refused whole: its date already has a log, it has more than `MAX_OPS` ops, or
/// the gate it came with is for another day.
fn refuse_batch(batch: &Batch, gate: Option<&Gate>, log_file: &Path) -> Result<()> {
    if log_file.exists() {
        bail!(
            "{} already exists: that date was applied",
            log_file.display()
        );
    }
    if batch.ops.len() > MAX_OPS {
        bail!("{} ops in one batch (max {MAX_OPS})", batch.ops.len());
    }
    if let Some(g) = gate.filter(|g| g.date != batch.date) {
        bail!(
            "the gate is for {} and the batch for {}",
            g.date,
            batch.date
        );
    }
    Ok(())
}

/// Source id -> path, for the ids an op may cite: the batch's sources and every gate item.
fn source_paths(batch: &Batch, gate: Option<&Gate>) -> BTreeMap<String, String> {
    let mut sources: BTreeMap<String, String> = batch
        .sources
        .iter()
        .map(|s| (s.id.clone(), s.path.clone()))
        .collect();
    for i in gate.into_iter().flat_map(|g| &g.items) {
        sources.insert(i.id.clone(), i.path.clone());
    }
    sources
}

/// What gets a disposition: every item the gate saw, or with no gate every source the batch names.
fn items_of(batch: &Batch, gate: Option<&Gate>) -> Vec<Item> {
    match gate {
        Some(g) => g.items.clone(),
        None => batch
            .sources
            .iter()
            .map(|s| Item {
                id: s.id.clone(),
                path: s.path.clone(),
                read: Some(s.path.clone()),
                ..Default::default()
            })
            .collect(),
    }
}

/// The model's reason per source id, for the sources no op cites.
fn reasons(batch: &Batch) -> BTreeMap<&str, &str> {
    batch
        .sources
        .iter()
        .filter(|s| !s.why.trim().is_empty())
        .map(|s| (s.id.as_str(), s.why.trim()))
        .collect()
}

/// Register each domain op the registry accepts, and return its Changes lines. A vault with no
/// registry refuses every one: the first domain turns the registry rules on for every page, so
/// a person makes it.
fn apply_domains<'a>(
    p: &Profile,
    log: &Logger,
    ops: impl Iterator<Item = &'a Op>,
    reg: &mut Option<registry::Registry>,
    date: NaiveDate,
    dry_run: bool,
    out: &mut Outcome,
) -> Result<Vec<String>> {
    let mut changes = Vec::new();
    for op in ops {
        let d = Domain {
            id: op.id.trim().to_string(),
            is: op.is.trim().to_string(),
            aliases: op.aliases.clone(),
            canonical: op.canonical.clone(),
        };
        let verdict = match reg.as_ref() {
            None => Err("the vault has no registry yet: its first domain is registered by hand (`notes knowledge domain add`)".to_string()),
            Some(r) => r.check_new(&d).map_err(|e| format!("{e:#}")),
        };
        if let Err(why) = verdict {
            out.rejected += 1;
            eprintln!("rejected domain {}: {why}", d.id);
            changes.push(format!("- rejected domain `{}`: {why}", d.id));
            continue;
        }
        out.domains += 1;
        changes.push(format!(
            "- registered domain `{}`: {}{}",
            d.id,
            d.is,
            cites(&op.sources)
        ));
        if !dry_run {
            registry::add(p, log, d.clone(), date)?;
        }
        if let Some(r) = reg.as_mut() {
            r.domain.push(d);
        }
    }
    Ok(changes)
}

/// What the batch's page ops did with each source id.
struct Compiled<'a> {
    /// source id -> the pages it went into
    pages: BTreeMap<String, Vec<String>>,
    /// the ids every op citing them was refused
    refused: HashSet<String>,
    /// the model's reason for a source no op cites
    why: BTreeMap<&'a str, &'a str>,
}

/// One Dispositions line per item: where it went. A todo list's open items are routed to the
/// outbox here, with the log, so a night that fails before it routes nothing.
fn settle(
    p: &Profile,
    log: &Logger,
    items: &[Item],
    c: &Compiled,
    dry_run: bool,
    out: &mut Outcome,
) -> Result<Vec<String>> {
    let mut dispositions = Vec::new();
    for item in items {
        let verdict = match item.kind {
            GateKind::Todo if item.tasks.is_empty() => {
                "skipped: a todo list with no open items".to_string()
            }
            GateKind::Todo => {
                let mut added = 0;
                for block in &item.tasks {
                    if dry_run || outbox::append(p, log, block)? {
                        added += 1;
                    }
                }
                out.routed += added;
                let waiting = item.tasks.len() - added;
                if waiting == 0 {
                    format!("routed to outbox: {added} item(s)")
                } else {
                    format!("routed to outbox: {added} item(s), {waiting} already waiting there")
                }
            }
            _ if item.read.is_none() => format!("skipped: {}", item.note),
            _ => match c.pages.get(&item.id) {
                Some(pages) => format!("compiled into {}", pages.join(", ")),
                None if c.refused.contains(&item.id) => {
                    "rejected: every op citing it was refused (see Changes)".to_string()
                }
                None => format!(
                    "rejected: {}",
                    c.why
                        .get(item.id.as_str())
                        .copied()
                        .unwrap_or("read, and no op cites it (no reason given)")
                ),
            },
        };
        let mut line = format!("- `{}` {}", item.id, source_ref(&item.path));
        if !item.part.is_empty() {
            line.push_str(&format!(" {}", item.part));
        }
        line.push_str(&format!(": {verdict}"));
        if item.read.is_some() && !item.note.is_empty() {
            line.push_str(&format!(" ({})", item.note));
        }
        dispositions.push(line);
    }
    Ok(dispositions)
}

/// The day's log: Changes, Warnings, Dispositions and the Sources with their excerpts.
fn render_log(
    batch: &Batch,
    changes: &[String],
    warnings: &[String],
    dispositions: &[String],
    any_read: bool,
) -> String {
    let mut s = format!(
        "---\ndate: {d}\ntags: [knowledge-log]\n---\n\n# Knowledge log {d}\n\n## Changes\n",
        d = batch.date
    );
    if changes.is_empty() {
        s.push_str(if any_read {
            "- none: nothing in the sources was worth keeping\n"
        } else {
            "- none: no source for the model to read\n"
        });
    }
    for c in changes {
        s.push_str(c);
        s.push('\n');
    }
    if !warnings.is_empty() {
        s.push_str("\n## Warnings\n");
        for w in warnings {
            s.push_str(&format!("- {w}\n"));
        }
    }
    if !dispositions.is_empty() {
        s.push_str(&format!("\n## {DISPOSITIONS}\n"));
        for d in dispositions {
            s.push_str(d);
            s.push('\n');
        }
    }
    s.push_str("\n## Sources\n");
    for src in &batch.sources {
        s.push_str(&format!("\n{}\n", source_heading(src)));
        if !src.excerpt.trim().is_empty() {
            s.push_str(&format!("{}\n", excerpt(src.excerpt.trim())));
        }
    }
    s
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
    let done = log_dates(p);
    let last = done.last().copied();
    let mut line = match (span, last) {
        (Some((first, last)), _) => {
            let when = if first == last {
                format!("{last}")
            } else {
                format!("{first} to {last}")
            };
            format!(
                "- Knowledge: {created} new, {updated} updated ({when}) [[{}]]",
                link(last)
            )
        }
        (None, Some(d)) => format!("- Knowledge: nothing new (last compiled [[{}]])", link(d)),
        (None, None) => return "- Knowledge: nothing compiled yet\n".to_string(),
    };
    // What the engine still owes and how far the pages drifted, each only when it is not zero.
    let owed = owed_days(&done, today).len();
    if owed > 0 {
        line.push_str(&format!("; pending: {owed} day(s)"));
    }
    match knowledge_lint::lint(p) {
        Ok(r) if r.total() > 0 => {
            line.push_str(&format!("; drift: {} (`notes knowledge lint`)", r.total()))
        }
        Ok(_) => {}
        Err(_) => line.push_str("; drift: lint failed (`notes knowledge lint`)"),
    }
    line.push('\n');
    line
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

/// Every date with a log under `knowledge/_log/YYYY/MM/` (`_log/originals/` is not a year).
fn log_dates(p: &Profile) -> BTreeSet<NaiveDate> {
    let mut out = BTreeSet::new();
    let Ok(years) = fs::read_dir(p.knowledge.join(LOG_DIR)) else {
        return out;
    };
    let year = |e: &fs::DirEntry| {
        let n = e.file_name().to_string_lossy().into_owned();
        n.len() == 4 && n.chars().all(|c| c.is_ascii_digit())
    };
    for y in years.flatten().filter(year) {
        for m in fs::read_dir(y.path()).into_iter().flatten().flatten() {
            for f in fs::read_dir(m.path()).into_iter().flatten().flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                if let Some(Ok(d)) = name
                    .strip_suffix(".md")
                    .map(|stem| NaiveDate::parse_from_str(stem, "%Y-%m-%d"))
                {
                    out.insert(d);
                }
            }
        }
    }
    out
}

/// The days the engine still owes, oldest first: every day from the first log through
/// yesterday that has no log. A vault with no log yet owes yesterday. Today is never due: its
/// note is still being written.
pub fn pending(p: &Profile, today: NaiveDate) -> Vec<NaiveDate> {
    owed_days(&log_dates(p), today)
}

/// [`pending`] over the dates already logged.
fn owed_days(done: &BTreeSet<NaiveDate>, today: NaiveDate) -> Vec<NaiveDate> {
    let yesterday = today - Duration::days(1);
    let first = done.first().copied().unwrap_or(yesterday).min(yesterday);
    first
        .iter_days()
        .take_while(|d| *d <= yesterday)
        .filter(|d| !done.contains(d))
        .collect()
}

/// A log's outcome per source. A log written before dispositions existed has none, so they are
/// rebuilt from its `### sN:` Sources headings and the ids its Changes lines cite.
fn dispositions_of(content: &str) -> (Vec<String>, bool) {
    if let Some(lines) = md::section_lines(content, DISPOSITIONS) {
        let lines = lines.into_iter().filter(|l| l.starts_with("- ")).collect();
        return (lines, false);
    }
    let changes = md::section_lines(content, "Changes").unwrap_or_default();
    let mut pages: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for c in &changes {
        let Some(rest) = c
            .strip_prefix("- created ")
            .or_else(|| c.strip_prefix("- updated "))
        else {
            continue;
        };
        let Some(link) = rest.split(':').next().filter(|l| l.starts_with("[[")) else {
            continue;
        };
        let ids = rest
            .rsplit_once(" (")
            .and_then(|(_, t)| t.strip_suffix(')'))
            .unwrap_or("");
        for id in ids.split(", ").filter(|s| !s.is_empty()) {
            pages
                .entry(id.to_string())
                .or_default()
                .push(link.to_string());
        }
    }
    let lines = md::section_lines(content, "Sources")
        .unwrap_or_default()
        .iter()
        .filter_map(|l| l.strip_prefix("### "))
        .filter_map(|l| l.split_once(": "))
        .map(|(id, src)| {
            let verdict = match pages.get(id) {
                Some(p) => format!("compiled into {}", p.join(", ")),
                None => "read, and no op cites it".to_string(),
            };
            format!("- `{id}` {src}: {verdict} (logged before dispositions)")
        })
        .collect();
    (lines, true)
}

#[derive(Clone, Copy, PartialEq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
enum Status {
    Logged,
    /// No log yet, and the engine owes it.
    Pending,
    /// No log, and none is owed.
    None,
}

#[derive(serde::Serialize)]
struct Traced {
    date: String,
    status: Status,
    rebuilt: bool,
    lines: Vec<String>,
}

impl Traced {
    fn bare(d: NaiveDate, status: Status) -> Self {
        Traced {
            date: d.to_string(),
            status,
            rebuilt: false,
            lines: Vec::new(),
        }
    }
}

fn print_traced(found: &[Traced], json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(found)?);
        return Ok(());
    }
    for t in found {
        match t.status {
            Status::Pending => println!("{}: pending, not compiled yet", t.date),
            Status::None => println!("{}: no log", t.date),
            Status::Logged => {
                println!("{}:", t.date);
                for l in &t.lines {
                    println!("  {l}");
                }
            }
        }
    }
    Ok(())
}

/// `notes knowledge trace <day|path>`: what the engine did with each source of a day, or where
/// one source went. Exit 1 when there is nothing to show.
pub fn trace(p: &Profile, target: &str, today: NaiveDate, json: bool) -> Result<i32> {
    let done = log_dates(p);
    let owed: HashSet<NaiveDate> = owed_days(&done, today).into_iter().collect();
    let read = |d: NaiveDate| fs::read_to_string(log_path(p, d)).ok();
    if let Ok(d) = NaiveDate::parse_from_str(target, "%Y-%m-%d") {
        let t = match read(d) {
            Some(c) => {
                let (lines, rebuilt) = dispositions_of(&c);
                Traced {
                    lines,
                    rebuilt,
                    ..Traced::bare(d, Status::Logged)
                }
            }
            None if owed.contains(&d) => Traced::bare(d, Status::Pending),
            None => Traced::bare(d, Status::None),
        };
        let code = i32::from(t.status == Status::None);
        print_traced(&[t], json)?;
        return Ok(code);
    }

    // A path: a log links a vault file by its path with no `.md`, and backticks one outside it.
    let root = format!("{}/", p.root.display());
    let raw = target
        .trim()
        .trim_start_matches("[[")
        .trim_end_matches("]]");
    let rel = raw.strip_prefix(&root).unwrap_or(raw);
    let key = source_key(rel);
    let needles = [format!("[[{key}]]"), format!("`{raw}`")];
    let hit = |l: &String| needles.iter().any(|n| l.contains(n.as_str()));
    // The day in the path first (a ref is compiled the night of its date), then every log.
    let dated = rel
        .split(['/', '.'])
        .find_map(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    let mut days: Vec<NaiveDate> = dated.into_iter().collect();
    days.extend(done.into_iter().rev().filter(|d| Some(*d) != dated));
    let mut found = Vec::new();
    for d in days {
        // Most logs never name the target; only one that does is worth parsing.
        let Some(c) = read(d).filter(|c| needles.iter().any(|n| c.contains(n.as_str()))) else {
            continue;
        };
        let (lines, rebuilt) = dispositions_of(&c);
        let lines: Vec<String> = lines.into_iter().filter(hit).collect();
        if !lines.is_empty() {
            found.push(Traced {
                lines,
                rebuilt,
                ..Traced::bare(d, Status::Logged)
            });
        }
    }
    if found.is_empty() {
        if let Some(d) = dated.filter(|d| owed.contains(d)) {
            print_traced(&[Traced::bare(d, Status::Pending)], json)?;
            return Ok(0);
        }
        if json {
            println!("[]");
        } else {
            println!("{key}: in no knowledge log");
        }
        return Ok(1);
    }
    print_traced(&found, json)?;
    Ok(0)
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
        apply(&profile(root), &logger(root), &f, None, false, None)
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
                op("create", "knowledge/x.txt", &a),
                op("create", "/etc/x.md", &a),
            ],
        )
        .unwrap();
        assert_eq!((out.created, out.rejected), (0, 6));
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
            None,
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
        apply(&profile(&root), &logger(&root), &f, None, false, None).unwrap();
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
        let out = apply(&profile(&root), &logger(&root), &f, None, true, None).unwrap();
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
        // The log is what this test reads; with no page left there is no drift to report.
        fs::remove_file(root.join("knowledge/software/gw.md")).unwrap();
        let today = NaiveDate::from_ymd_opt(2026, 10, 14).unwrap();

        let lines = morning_lines(&p, Some("# yesterday\n"), today);
        assert_eq!(
            lines,
            "- Knowledge: 1 new, 0 updated (2026-10-13) [[knowledge/_log/2026/10/2026-10-13]]\n"
        );
        // Tomorrow's note sees today's note already listed it, and still links the log; the
        // day between has no log, so it is owed.
        let quiet = morning_lines(&p, Some(&lines), today + Duration::days(1));
        assert_eq!(
            quiet,
            "- Knowledge: nothing new (last compiled [[knowledge/_log/2026/10/2026-10-13]]); pending: 1 day(s)\n"
        );
        // The day after a quiet note, the log is still not listed again.
        assert_eq!(
            morning_lines(&p, Some(&quiet), today + Duration::days(2)),
            quiet.replace("1 day(s)", "2 day(s)")
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

    fn domain_op(id: &str, aliases: &[&str]) -> String {
        serde_json::json!({"op": "domain", "id": id, "is": "what goes here", "aliases": aliases, "sources": ["s1"]})
            .to_string()
    }

    #[test]
    fn a_domain_op_registers_one_unless_its_name_is_taken_or_there_is_no_registry() {
        let root = vault("domain-op");
        // No registry: the first domain is the human's to make.
        let out = run(&root, &[domain_op("subjects/biology", &[])]).unwrap();
        assert_eq!((out.domains, out.rejected), (0, 1));
        assert!(
            rejections(&out).contains("registered by hand"),
            "{}",
            rejections(&out)
        );
        assert!(!registry::path(&profile(&root)).exists());

        let root = vault("domain-op2");
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 10, 1).unwrap();
        let ops = Domain {
            id: "core/ops".into(),
            is: "how we run things".into(),
            aliases: vec!["release".into()],
            canonical: Vec::new(),
        };
        registry::add(&p, &logger(&root), ops, today).unwrap();
        let out = run(
            &root,
            &[
                domain_op("subjects/biology", &["bio"]),
                domain_op("subjects/release", &[]),
            ],
        )
        .unwrap();
        assert_eq!((out.domains, out.rejected), (1, 1), "{}", rejections(&out));
        let log = rejections(&out);
        assert!(
            log.contains("- registered domain `subjects/biology`: what goes here (s1)"),
            "{log}"
        );
        assert!(
            log.contains("- rejected domain `subjects/release`"),
            "{log}"
        );
        let reg = registry::load(&p).unwrap().unwrap();
        let ids: Vec<&str> = reg.domain.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids, ["core/ops", "subjects/biology"]);
        assert!(root.join("knowledge/subjects/biology/index.md").exists());
        let _ = fs::remove_dir_all(&root);
    }

    fn item(id: &str, path: &str, kind: GateKind, read: bool) -> Item {
        Item {
            id: id.into(),
            path: path.into(),
            kind,
            read: read.then(|| path.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn every_gated_source_gets_a_disposition_and_todo_items_go_to_the_outbox() {
        let root = vault("dispositions");
        let p = profile(&root);
        let refs = "journal/refs/2026-10-13";
        let todo = Item {
            tasks: vec![
                vec!["- [ ] buy filament".into(), "  - PETG".into()],
                vec!["- [ ] fix the gate".into()],
            ],
            ..item("s3", &format!("{refs}/ingest.md"), GateKind::Todo, false)
        };
        let gate = Gate {
            date: "2026-10-13".into(),
            items: vec![
                item("s1", "journal/daily/2026-10-13.md", GateKind::Note, true),
                item("s2", &format!("{refs}/chat.md"), GateKind::Transcript, true),
                todo,
                Item {
                    note: "generated by a tool".into(),
                    ..item("s4", &format!("{refs}/_index.md"), GateKind::Index, false)
                },
            ],
        };
        let json = format!(
            r#"{{"date":"2026-10-13","sources":[{{"id":"s2","path":"{refs}/chat.md","excerpt":"","why":"a chat about lunch"}}],"ops":[{}]}}"#,
            op("create", "knowledge/software/gw.md", &article("gw", "body"))
        );
        let f = batch(&root, &json);
        let out = apply(&p, &logger(&root), &f, None, false, Some(&gate)).unwrap();
        assert_eq!((out.created, out.routed), (1, 2));
        let log = fs::read_to_string(&out.log).unwrap();
        let lines = md::section_lines(&log, DISPOSITIONS).unwrap().join("\n");
        assert_eq!(
            lines,
            "- `s1` [[journal/daily/2026-10-13]]: compiled into [[knowledge/software/gw]]\n\
             - `s2` [[journal/refs/2026-10-13/chat]]: rejected: a chat about lunch\n\
             - `s3` [[journal/refs/2026-10-13/ingest]]: routed to outbox: 2 item(s)\n\
             - `s4` [[journal/refs/2026-10-13/_index]]: skipped: generated by a tool"
        );
        let outbox = fs::read_to_string(&p.outbox).unwrap();
        assert!(outbox.contains("- [ ] buy filament\n  - PETG"), "{outbox}");
        assert!(outbox.contains("- [ ] fix the gate"), "{outbox}");
        let added = || {
            fs::read_to_string(crate::ingest::path(&p))
                .unwrap_or_default()
                .matches(r#""action":"added","from":"outbox""#)
                .count()
        };
        assert_eq!(added(), 2, "each routed item is in the ingest record");

        // Trace a source by its path, and a day: both read the Dispositions.
        let today = NaiveDate::from_ymd_opt(2026, 10, 14).unwrap();
        assert_eq!(
            trace(&p, &format!("{refs}/ingest.md"), today, false).unwrap(),
            0
        );
        assert_eq!(trace(&p, "2026-10-13", today, false).unwrap(), 0);
        assert_eq!(
            trace(&p, "journal/refs/2026-10-13/nope.md", today, false).unwrap(),
            1
        );
        assert_eq!(trace(&p, "2026-10-01", today, false).unwrap(), 1);

        // A second night with the same items routes nothing twice.
        let gate2 = Gate {
            date: "2026-10-14".into(),
            items: gate.items[2..3].to_vec(),
        };
        let f = batch(&root, r#"{"date":"2026-10-14","sources":[],"ops":[]}"#);
        let out = apply(&p, &logger(&root), &f, None, false, Some(&gate2)).unwrap();
        assert_eq!(out.routed, 0);
        let log = fs::read_to_string(&out.log).unwrap();
        assert!(
            log.contains("- none: no source for the model to read"),
            "{log}"
        );
        assert!(
            log.contains("routed to outbox: 0 item(s), 2 already waiting there"),
            "{log}"
        );
        assert_eq!(added(), 2, "an item already waiting is not recorded again");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_gate_for_another_day_is_refused() {
        let root = vault("gate-date");
        let gate = Gate {
            date: "2026-10-12".into(),
            items: Vec::new(),
        };
        let f = batch(&root, r#"{"date":"2026-10-13","sources":[],"ops":[]}"#);
        let err = apply(
            &profile(&root),
            &logger(&root),
            &f,
            None,
            false,
            Some(&gate),
        )
        .unwrap_err();
        assert!(
            err.to_string().contains("the gate is for 2026-10-12"),
            "{err}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_log_from_before_dispositions_is_rebuilt_from_its_sources_and_changes() {
        let old = "# Knowledge log\n\n## Changes\n- created [[knowledge/a]]: why (s1, s2)\n- updated [[knowledge/b]]: why (s2)\n\n## Sources\n\n### s1: [[journal/daily/2026-10-13]]\n> x\n\n### s2: `/home/u/.agent/sessions/w.md`\n\n### s3: [[journal/refs/2026-10-13/r]]\n";
        let (lines, rebuilt) = dispositions_of(old);
        assert!(rebuilt);
        assert_eq!(
            lines,
            [
                "- `s1` [[journal/daily/2026-10-13]]: compiled into [[knowledge/a]] (logged before dispositions)",
                "- `s2` `/home/u/.agent/sessions/w.md`: compiled into [[knowledge/a]], [[knowledge/b]] (logged before dispositions)",
                "- `s3` [[journal/refs/2026-10-13/r]]: read, and no op cites it (logged before dispositions)",
            ]
        );
    }

    #[test]
    fn every_day_since_the_first_log_without_one_is_pending_however_old() {
        let root = vault("pending");
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        // No log yet: only yesterday is owed.
        assert_eq!(pending(&p, today), [today - Duration::days(1)]);
        run(&root, &[]).unwrap(); // 2026-10-13
        let log = |d: &str| {
            let f = root.join(format!("knowledge/_log/2026/10/{d}.md"));
            fs::write(f, "# log\n").unwrap();
        };
        log("2026-10-15");
        log("2026-10-19");
        // `_log/originals/` holds copies, not logs.
        fs::create_dir_all(root.join("knowledge/_log/originals/2026")).unwrap();
        let days: Vec<String> = pending(&p, today).iter().map(|d| d.to_string()).collect();
        // 10-14 is six days back: there is no lookback cap.
        assert_eq!(
            days,
            ["2026-10-14", "2026-10-16", "2026-10-17", "2026-10-18"]
        );
        assert_eq!(trace(&p, "2026-10-14", today, false).unwrap(), 0);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_morning_line_counts_owed_days_and_drift() {
        let root = vault("morning-owed");
        run(
            &root,
            &[op(
                "create",
                "knowledge/software/gw.md",
                &article("gw", "b"),
            )],
        )
        .unwrap();
        let p = profile(&root);
        let today = NaiveDate::from_ymd_opt(2026, 10, 17).unwrap();
        // No registry, so the page is unregistered: one finding.
        assert_eq!(
            morning_lines(&p, None, today),
            "- Knowledge: 1 new, 0 updated (2026-10-13) [[knowledge/_log/2026/10/2026-10-13]]; pending: 3 day(s); drift: 1 (`notes knowledge lint`)\n"
        );
        let _ = fs::remove_dir_all(&root);
    }
}
