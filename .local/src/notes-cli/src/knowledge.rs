//! `notes knowledge` - the write side of the compiled knowledge base under `knowledge/`.
//!
//! The nightly knowledge engine is a model with READ-only tools. It never writes a file: it
//! hands back a batch of ops as JSON, and `apply` is the one writer. That keeps every guard
//! in tested code instead of in a prompt:
//!
//!   - an op may only touch `knowledge/**/*.md`, never `knowledge/_log/` or the schema;
//!   - an update loses to a human edit made while the engine was running (`--started`);
//!   - an update may not silently gut an article (the shrink guard);
//!   - a hand-written article is copied to `_log/originals/` the first time it is rewritten;
//!   - every date gets exactly one immutable log, `_log/YYYY/MM/YYYY-MM-DD.md`, which is also
//!     the checkpoint: git syncs it, so no machine re-runs a date another already did.
//!
//! `new_section` renders the daily note's `## New knowledge` from those logs.

use crate::config::{self, Profile};
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::{Duration, NaiveDate};
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

const SCHEMA_TEMPLATE: &str = include_str!("knowledge_schema.md");
const SCHEMA_FILE: &str = "SCHEMA.md";
const LOG_DIR: &str = "_log";
/// A batch bigger than this is a model that lost the plot, not a busy night.
const MAX_OPS: usize = 20;
/// An update may shrink an article to no less than this share of its size without a reason.
const MIN_KEEP_PCT: usize = 60;
/// Frontmatter keys every article must carry.
const REQUIRED: [&str; 4] = ["title", "summary", "tags", "updated"];
/// How far back the daily note looks for logs it has not listed yet.
const NEW_SECTION_DAYS: i64 = 7;
/// Articles listed per log in the daily note before collapsing to "+N more".
const NEW_SECTION_CAP: usize = 10;
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
fn frontmatter(content: &str) -> Option<BTreeMap<String, String>> {
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

/// The tag vocabulary: every backticked word in the schema's `## Tags` section. The vault copy
/// wins so a local addition counts; the built-in template is the fallback.
fn tag_vocab(p: &Profile) -> HashSet<String> {
    let schema = fs::read_to_string(p.knowledge.join(SCHEMA_FILE))
        .unwrap_or_else(|_| SCHEMA_TEMPLATE.to_string());
    let lines = md::section_lines(&schema, "Tags").unwrap_or_default();
    let mut out = HashSet::new();
    for line in lines {
        for (i, part) in line.split('`').enumerate() {
            if i % 2 == 1 && !part.is_empty() {
                out.insert(part.to_string());
            }
        }
    }
    out
}

fn list_tags(raw: &str) -> Vec<String> {
    raw.trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Every article under `knowledge/`: markdown, outside `_log/`, not the schema.
fn articles(p: &Profile) -> Vec<PathBuf> {
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

/// Write `knowledge/SCHEMA.md` from the built-in template. Refuses to overwrite unless `force`.
pub fn init(p: &Profile, log: &Logger, force: bool) -> Result<()> {
    let file = p.knowledge.join(SCHEMA_FILE);
    if file.exists() && !force {
        println!("{} exists (use --force to rewrite it)", file.display());
        return Ok(());
    }
    fs::create_dir_all(&p.knowledge)?;
    md::write_atomic(&file, SCHEMA_TEMPLATE)?;
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

/// Check one op against the vault as it stands. Ok = the file to write; Err = why not.
fn check(
    p: &Profile,
    op: &Op,
    started: Option<i64>,
    vocab: &HashSet<String>,
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
    for tag in list_tags(&fm["tags"]) {
        if !vocab.contains(&tag) {
            warnings.push(format!("`{}`: tag `{tag}` is not in the schema", op.path));
        }
    }
    match op.op.as_str() {
        "create" => {
            if file.exists() {
                return Err("create on a file that exists (use update)".into());
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
        }
        other => return Err(format!("unknown op `{other}`")),
    }
    Ok(file)
}

fn source_heading(p: &Profile, s: &Source) -> String {
    let in_vault = !s.path.starts_with('/') && !s.path.starts_with('~');
    if in_vault {
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

    let vocab = tag_vocab(p);
    let known: HashSet<&str> = batch.sources.iter().map(|s| s.id.as_str()).collect();
    let mut warnings = Vec::new();
    let mut seen = HashSet::new();
    let mut changes = Vec::new();
    let mut out = Outcome {
        log: log_file.clone(),
        ..Default::default()
    };

    for op in &batch.ops {
        let verdict = if seen.insert(op.path.clone()) {
            check(p, op, started, &vocab, &mut warnings)
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
        for id in op.sources.iter().filter(|id| !known.contains(id.as_str())) {
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

/// The daily note's `## New knowledge`: every log from the last week that the previous note did
/// not already list, oldest first, with the articles it created or updated. Keyed on the
/// previous note's content rather than on dates, so a log that lands after today's note was
/// created shows up tomorrow instead of never. Empty string when there is nothing new.
pub fn new_section(p: &Profile, prev_note: Option<&str>, today: NaiveDate) -> String {
    let mut block = String::new();
    for back in (1..=NEW_SECTION_DAYS).rev() {
        let file = log_path(p, today - Duration::days(back));
        let Ok(content) = fs::read_to_string(&file) else {
            continue;
        };
        let link = config::wikilink(&p.root, &file);
        if prev_note.is_some_and(|prev| prev.contains(&format!("[[{link}]]"))) {
            continue;
        }
        let items: Vec<String> = md::section_lines(&content, "Changes")
            .unwrap_or_default()
            .iter()
            .filter_map(|l| {
                let (verb, rest) = if let Some(r) = l.strip_prefix("- created [[") {
                    ("new", r)
                } else {
                    ("updated", l.strip_prefix("- updated [[")?)
                };
                let target = rest.split("]]").next()?;
                Some(format!("  - {verb} [[{target}]]"))
            })
            .collect();
        if items.is_empty() {
            continue;
        }
        block.push_str(&format!("- [[{link}]]\n"));
        for item in items.iter().take(NEW_SECTION_CAP) {
            block.push_str(item);
            block.push('\n');
        }
        if items.len() > NEW_SECTION_CAP {
            block.push_str(&format!("  - +{} more\n", items.len() - NEW_SECTION_CAP));
        }
    }
    if block.is_empty() {
        return block;
    }
    format!("\n## New knowledge\n{block}")
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
            "---\ntitle: {title}\nsummary: what {title} is\ntags: [software, reference]\nupdated: 2026-10-13\nsources: [2026-10-13]\n---\n\n# {title}\n\n{body}\n"
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
        apply(&profile(root), &logger(root), &f, None, false)
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
        let out = apply(&profile(&root), &logger(&root), &f, Some(started), false).unwrap();
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
        apply(&profile(&root), &logger(&root), &f, None, false).unwrap();
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
        let out = apply(&profile(&root), &logger(&root), &f, None, true).unwrap();
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
    fn unknown_tags_warn_but_apply() {
        let root = vault("tags");
        let a = article("a", "b").replace("[software, reference]", "[software, madeup]");
        let out = run(&root, &[op("create", "knowledge/a.md", &a)]).unwrap();
        assert_eq!(out.created, 1);
        let log = fs::read_to_string(&out.log).unwrap();
        assert!(log.contains("tag `madeup` is not in the schema"), "{log}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn new_section_lists_each_log_once() {
        let root = vault("newsec");
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

        let sec = new_section(&p, Some("# yesterday\n"), today);
        assert_eq!(
            sec,
            "\n## New knowledge\n- [[knowledge/_log/2026/10/2026-10-13]]\n  - new [[knowledge/software/gw]]\n"
        );
        // Tomorrow's note sees today's note already listed it.
        assert_eq!(new_section(&p, Some(&sec), today + Duration::days(1)), "");
        // Nothing logged: no section at all.
        assert_eq!(new_section(&profile(&vault("empty")), None, today), "");
        let _ = fs::remove_dir_all(&root);
    }
}
