//! `notes knowledge mv`: move a knowledge page, or retire one already merged into another, and
//! rewrite every link to it across the vault in the same pass.
//!
//! Links are `[[knowledge/a/b]]` wikilinks (with an optional `.md`, `#anchor` or `|alias`) and
//! relative markdown links (`](../b.md)`). The compile log under `knowledge/_log/` is immutable
//! and `_archive/` keeps what it archived as written, so neither is rewritten. A moved page's own
//! relative links are re-based on its new folder. A batch (`--map`) walks the vault once.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

/// One move: vault-relative paths with `.md`. `merged` means `to` already holds `from`'s facts,
/// so `from` is deleted and its links point at `to`.
#[derive(Debug, Clone)]
pub struct Move {
    pub from: String,
    pub to: String,
    pub merged: bool,
}

/// What a run did, for the summary line and the tests.
#[derive(Debug, Default)]
pub struct Outcome {
    pub moved: usize,
    pub retired: usize,
    /// files whose links were rewritten, with the number of links in each
    pub rewritten: Vec<(String, usize)>,
}

/// `a/b`, `a/b.md` or `./a/b.md` -> `a/b.md`; refuses an absolute path or one that climbs out.
fn rel_md(s: &str) -> Result<String> {
    let s = s.trim().trim_start_matches("./");
    let p = Path::new(s);
    if s.is_empty() || p.is_absolute() || p.components().any(|c| !matches!(c, Component::Normal(_)))
    {
        bail!("`{s}`: give a vault-relative path such as knowledge/core/ops/ci.md");
    }
    Ok(if s.ends_with(".md") {
        s.to_string()
    } else {
        format!("{s}.md")
    })
}

/// Parse `--map`: one move per line, `from<TAB>to[<TAB>merged]`; blank and `#` lines skip.
pub fn parse_map(text: &str) -> Result<Vec<Move>> {
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let line = line.trim_end();
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        let merged = match cols.get(2).map(|c| c.trim()) {
            None | Some("") => false,
            Some("merged") => true,
            Some(other) => bail!(
                "map line {}: third column `{other}`, expected `merged`",
                n + 1
            ),
        };
        if cols.len() < 2 || cols.len() > 3 {
            bail!("map line {}: expected from<TAB>to[<TAB>merged]", n + 1);
        }
        out.push(Move {
            from: rel_md(cols[0])?,
            to: rel_md(cols[1])?,
            merged,
        });
    }
    Ok(out)
}

pub fn single(from: &str, to: &str, merged: bool) -> Result<Move> {
    Ok(Move {
        from: rel_md(from)?,
        to: rel_md(to)?,
        merged,
    })
}

/// Every move checked before anything is touched, so a bad batch changes nothing.
fn validate(p: &Profile, moves: &[Move]) -> Result<()> {
    let log_dir = "knowledge/_log/";
    let mut seen_from = std::collections::HashSet::new();
    let froms: std::collections::HashSet<&str> = moves.iter().map(|m| m.from.as_str()).collect();
    let mut new_to = std::collections::HashSet::new();
    for m in moves {
        if !m.from.starts_with("knowledge/") || m.from.starts_with(log_dir) {
            bail!("{}: only a knowledge page outside _log/ moves", m.from);
        }
        if !(m.to.starts_with("knowledge/") || m.to.starts_with("_archive/"))
            || m.to.starts_with(log_dir)
        {
            bail!(
                "{} -> {}: the target sits under knowledge/ (not _log/) or _archive/",
                m.from,
                m.to
            );
        }
        if m.from == m.to {
            bail!("{}: moves onto itself", m.from);
        }
        if !seen_from.insert(m.from.as_str()) {
            bail!("{}: listed twice", m.from);
        }
        if !p.root.join(&m.from).is_file() {
            bail!("{}: no such page", m.from);
        }
        if froms.contains(m.to.as_str()) {
            bail!("{} -> {}: the target moves too in this batch", m.from, m.to);
        }
        let exists = p.root.join(&m.to).exists();
        if m.merged && !exists {
            bail!(
                "{} -> {}: `merged` needs the target page to exist",
                m.from,
                m.to
            );
        }
        if !m.merged && (exists || !new_to.insert(m.to.as_str())) {
            bail!(
                "{} -> {}: the target exists; merge the page into it and mark it `merged`",
                m.from,
                m.to
            );
        }
    }
    Ok(())
}

/// The relative path from directory `from_dir` to `to`, both vault-relative.
fn relative(from_dir: &Path, to: &Path) -> String {
    let a: Vec<_> = from_dir.components().collect();
    let b: Vec<_> = to.components().collect();
    let common = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut parts: Vec<String> = vec!["..".into(); a.len() - common];
    parts.extend(
        b[common..]
            .iter()
            .map(|c| c.as_os_str().to_string_lossy().into_owned()),
    );
    parts.join("/")
}

/// Resolve a relative link target against `dir` (vault-relative), lexically.
fn join_lexical(dir: &Path, target: &str) -> Option<PathBuf> {
    let mut out: Vec<String> = dir
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop()?;
            }
            p => out.push(p.to_string()),
        }
    }
    Some(out.iter().collect())
}

/// Rewrite `[[target...]]` wikilinks whose target is a key of `map` (paths without `.md`).
fn rewrite_wikilinks(content: &str, map: &HashMap<String, String>) -> (String, usize) {
    let mut out = String::with_capacity(content.len());
    let mut n = 0;
    let mut rest = content;
    while let Some(start) = rest.find("[[") {
        out.push_str(&rest[..start + 2]);
        rest = &rest[start + 2..];
        let Some(end) = rest.find("]]") else { break };
        let inner = &rest[..end];
        let cut = inner.find(['|', '#']).unwrap_or(inner.len());
        let (target, tail) = inner.split_at(cut);
        let bare = target.trim().strip_suffix(".md").unwrap_or(target.trim());
        match map.get(bare) {
            Some(new) if !inner.contains('\n') => {
                let ext = if target.trim().ends_with(".md") {
                    ".md"
                } else {
                    ""
                };
                out.push_str(&format!("{new}{ext}{tail}"));
                n += 1;
            }
            _ => out.push_str(inner),
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
    (out, n)
}

/// Rewrite relative `](target.md...)` links in a file at `old_dir`, now living at `new_dir`,
/// whose resolved target is a key of `moved` (vault-relative `.md` paths) or, when the file
/// itself moved, any relative target at all.
fn rewrite_relative(
    content: &str,
    old_dir: &Path,
    new_dir: &Path,
    moved: &HashMap<String, String>,
) -> (String, usize) {
    let mut out = String::with_capacity(content.len());
    let mut n = 0;
    let mut rest = content;
    while let Some(start) = rest.find("](") {
        out.push_str(&rest[..start + 2]);
        rest = &rest[start + 2..];
        let Some(end) = rest.find(')') else { break };
        let raw = &rest[..end];
        let (target, anchor) = raw.split_at(raw.find('#').unwrap_or(raw.len()));
        let local = !target.is_empty()
            && !target.contains("://")
            && !target.starts_with(['/', '~', '<', '#'])
            && !target.starts_with("mailto:")
            && !target.contains(char::is_whitespace);
        let decoded = target.replace("%20", " ");
        let resolved = local.then(|| join_lexical(old_dir, &decoded)).flatten();
        let new_target = resolved.and_then(|r| {
            let key = r.to_string_lossy().into_owned();
            match moved.get(&key) {
                Some(dest) => Some(PathBuf::from(dest)),
                None if old_dir != new_dir => Some(r),
                None => None,
            }
        });
        match new_target {
            Some(t) => {
                let mut s = relative(new_dir, &t);
                if target.contains("%20") {
                    s = s.replace(' ', "%20");
                }
                if s != target {
                    n += 1;
                }
                out.push_str(&s);
                out.push_str(anchor);
            }
            None => out.push_str(raw),
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
    (out, n)
}

/// Every markdown file the rewrite reads: the whole root but hidden dirs, the log and the archive.
fn vault_files(root: &Path) -> Vec<PathBuf> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let path = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let rel = path.strip_prefix(root).unwrap_or(&path);
            if rel == Path::new("knowledge/_log") || rel == Path::new("_archive") {
                continue;
            }
            match e.file_type() {
                Ok(t) if t.is_dir() => walk(root, &path, out),
                Ok(_) if name.ends_with(".md") => out.push(path),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out.sort();
    out
}

pub fn run(p: &Profile, log: &Logger, moves: &[Move], dry_run: bool) -> Result<Outcome> {
    if moves.is_empty() {
        bail!("nothing to move: give FROM TO or --map FILE");
    }
    validate(p, moves)?;
    let wiki: HashMap<String, String> = moves
        .iter()
        .map(|m| {
            let strip = |s: &str| s.strip_suffix(".md").unwrap_or(s).to_string();
            (strip(&m.from), strip(&m.to))
        })
        .collect();
    let by_from: HashMap<String, String> = moves
        .iter()
        .map(|m| (m.from.clone(), m.to.clone()))
        .collect();
    let merged: std::collections::HashSet<&str> = moves
        .iter()
        .filter(|m| m.merged)
        .map(|m| m.from.as_str())
        .collect();

    let mut outcome = Outcome::default();
    for f in vault_files(&p.root) {
        let rel = f.strip_prefix(&p.root).unwrap_or(&f).to_path_buf();
        let rel_s = rel.to_string_lossy().into_owned();
        if merged.contains(rel_s.as_str()) {
            continue; // its facts already live in the target; it is deleted below
        }
        let old_dir = rel.parent().unwrap_or(Path::new("")).to_path_buf();
        let dest = by_from.get(&rel_s).map(PathBuf::from);
        let new_dir = dest
            .as_ref()
            .and_then(|d| d.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| old_dir.clone());
        let Ok(content) = fs::read_to_string(&f) else {
            continue;
        };
        let (c1, a) = rewrite_wikilinks(&content, &wiki);
        let (c2, b) = rewrite_relative(&c1, &old_dir, &new_dir, &by_from);
        let out_rel = dest.clone().unwrap_or_else(|| rel.clone());
        if a + b > 0 {
            outcome
                .rewritten
                .push((out_rel.to_string_lossy().into_owned(), a + b));
        }
        if dry_run {
            continue;
        }
        if let Some(d) = &dest {
            let target = p.root.join(d);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("create {}", parent.display()))?;
            }
            fs::write(&target, &c2).with_context(|| format!("write {}", target.display()))?;
            fs::remove_file(&f).with_context(|| format!("remove {}", f.display()))?;
        } else if a + b > 0 {
            fs::write(&f, &c2).with_context(|| format!("write {}", f.display()))?;
        }
    }
    for m in moves {
        if m.merged {
            outcome.retired += 1;
            if !dry_run {
                fs::remove_file(p.root.join(&m.from))
                    .with_context(|| format!("remove {}", m.from))?;
            }
        } else {
            outcome.moved += 1;
        }
        if !dry_run {
            log.info(
                "knowledge mv",
                &format!(
                    "{} -> {}{}",
                    m.from,
                    m.to,
                    if m.merged { " (merged)" } else { "" }
                ),
            );
        }
    }
    if !dry_run {
        prune_empty_dirs(&p.knowledge, &p.knowledge.join("_log"));
    }
    Ok(outcome)
}

/// A folder a move emptied goes too, so the old area does not linger as an empty tree.
fn prune_empty_dirs(dir: &Path, keep: &Path) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    let mut empty = true;
    for e in entries.flatten() {
        let path = e.path();
        if path.is_dir() && path != keep && !e.file_name().to_string_lossy().starts_with('.') {
            if prune_empty_dirs(&path, keep) {
                let _ = fs::remove_dir(&path);
            } else {
                empty = false;
            }
        } else {
            empty = false;
        }
    }
    empty
}

pub fn print(o: &Outcome, dry_run: bool) {
    for (f, n) in &o.rewritten {
        println!("{f}\t{n} link(s)");
    }
    println!(
        "knowledge mv{}: {} moved, {} retired into their merge target, {} link(s) in {} file(s)",
        if dry_run { " (dry run)" } else { "" },
        o.moved,
        o.retired,
        o.rewritten.iter().map(|(_, n)| n).sum::<usize>(),
        o.rewritten.len()
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-kmv-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("knowledge/_log")).unwrap();
        dir
    }

    fn write(root: &Path, rel: &str, body: &str) {
        let f = root.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(f, body).unwrap();
    }

    fn read(root: &Path, rel: &str) -> String {
        fs::read_to_string(root.join(rel)).unwrap()
    }

    fn setup(name: &str) -> (PathBuf, Profile, Logger) {
        let root = vault(name);
        let p = config::test_profile(root.to_str().unwrap());
        let log = Logger::new(root.join("log.txt"), false);
        (root, p, log)
    }

    #[test]
    fn a_move_rewrites_every_link_form_but_the_log_and_the_archive() {
        let (root, p, log) = setup("forms");
        write(
            &root,
            "knowledge/software/a.md",
            "# A\n\nsee [sib](b.md) and [up](../top.md#x)\n",
        );
        write(&root, "knowledge/software/b.md", "# B\n\n[[knowledge/software/a]] [[knowledge/software/a.md|A]] [[knowledge/software/a#h]] [rel](a.md#y) [web](https://x/a.md)\n");
        write(&root, "knowledge/top.md", "# T\n");
        write(
            &root,
            "journal/daily_archive/d.md",
            "[[knowledge/software/a]] [[knowledge/software/ab]]\n",
        );
        write(
            &root,
            "knowledge/_log/2026/x.md",
            "[[knowledge/software/a]]\n",
        );
        write(&root, "_archive/old.md", "[[knowledge/software/a]]\n");

        let m = single("knowledge/software/a", "knowledge/core/ops/a.md", false).unwrap();
        let o = run(&p, &log, &[m], false).unwrap();
        assert_eq!(o.moved, 1);

        assert!(!root.join("knowledge/software/a.md").exists());
        // the moved page's own relative links follow it to the new folder
        assert_eq!(
            read(&root, "knowledge/core/ops/a.md"),
            "# A\n\nsee [sib](../../software/b.md) and [up](../../top.md#x)\n"
        );
        assert_eq!(
            read(&root, "knowledge/software/b.md"),
            "# B\n\n[[knowledge/core/ops/a]] [[knowledge/core/ops/a.md|A]] [[knowledge/core/ops/a#h]] [rel](../core/ops/a.md#y) [web](https://x/a.md)\n"
        );
        // a link that only shares a prefix is someone else's
        assert_eq!(
            read(&root, "journal/daily_archive/d.md"),
            "[[knowledge/core/ops/a]] [[knowledge/software/ab]]\n"
        );
        assert_eq!(
            read(&root, "knowledge/_log/2026/x.md"),
            "[[knowledge/software/a]]\n"
        );
        assert_eq!(read(&root, "_archive/old.md"), "[[knowledge/software/a]]\n");
    }

    #[test]
    fn a_merged_page_is_retired_and_its_links_point_at_the_target() {
        let (root, p, log) = setup("merged");
        write(
            &root,
            "knowledge/software/day-2026-11-01.md",
            "# old diary\n",
        );
        write(&root, "knowledge/core/agents/dispatch.md", "# Dispatch\n");
        write(
            &root,
            "knowledge/x.md",
            "[[knowledge/software/day-2026-11-01]]\n",
        );
        let moves =
            parse_map("# header\nknowledge/software/day-2026-11-01.md\tknowledge/core/agents/dispatch.md\tmerged\n")
                .unwrap();
        let o = run(&p, &log, &moves, false).unwrap();
        assert_eq!((o.moved, o.retired), (0, 1));
        assert!(!root.join("knowledge/software/day-2026-11-01.md").exists());
        assert_eq!(
            read(&root, "knowledge/core/agents/dispatch.md"),
            "# Dispatch\n"
        );
        assert_eq!(
            read(&root, "knowledge/x.md"),
            "[[knowledge/core/agents/dispatch]]\n"
        );
        // the emptied folder goes, the log stays
        assert!(!root.join("knowledge/software").exists());
        assert!(root.join("knowledge/_log").exists());
    }

    #[test]
    fn a_batch_moves_pages_that_link_each_other() {
        let (root, p, log) = setup("batch");
        write(
            &root,
            "knowledge/a/one.md",
            "[two](two.md) [[knowledge/a/two]]\n",
        );
        write(&root, "knowledge/a/two.md", "[one](one.md)\n");
        let moves = parse_map(
            "knowledge/a/one.md\tknowledge/core/x/one.md\nknowledge/a/two.md\tknowledge/subjects/y/two.md\n",
        )
        .unwrap();
        run(&p, &log, &moves, false).unwrap();
        assert_eq!(
            read(&root, "knowledge/core/x/one.md"),
            "[two](../../subjects/y/two.md) [[knowledge/subjects/y/two]]\n"
        );
        assert_eq!(
            read(&root, "knowledge/subjects/y/two.md"),
            "[one](../../core/x/one.md)\n"
        );
    }

    #[test]
    fn a_bad_batch_changes_nothing() {
        let (root, p, log) = setup("bad");
        write(&root, "knowledge/a.md", "# A\n");
        write(&root, "knowledge/b.md", "# B\n");
        write(&root, "knowledge/c.md", "[[knowledge/a]]\n");
        let cases = [
            "knowledge/a.md\tknowledge/b.md\n", // target exists, not merged
            "knowledge/a.md\tknowledge/new.md\tmerged\n", // merged into nothing
            "knowledge/a.md\tknowledge/_log/a.md\n", // into the log
            "knowledge/a.md\tlab/a.md\n",       // out of the knowledge base
            "knowledge/a.md\tknowledge/n.md\nknowledge/missing.md\tknowledge/m.md\n", // second is bad
            "knowledge/a.md\tknowledge/n.md\nknowledge/b.md\tknowledge/n.md\n", // two onto one
            "knowledge/a.md\tknowledge/n.md\nknowledge/c.md\tknowledge/a.md\n", // target moves away
            "../x.md\tknowledge/n.md\n",
        ];
        for case in cases {
            let moves = parse_map(case);
            assert!(
                moves.is_err() || run(&p, &log, &moves.unwrap(), false).is_err(),
                "accepted: {case}"
            );
        }
        assert_eq!(read(&root, "knowledge/c.md"), "[[knowledge/a]]\n");
        assert!(root.join("knowledge/a.md").exists());
        assert!(!root.join("knowledge/n.md").exists());
    }

    #[test]
    fn a_dry_run_reports_and_writes_nothing() {
        let (root, p, log) = setup("dry");
        write(&root, "knowledge/a.md", "# A\n");
        write(&root, "knowledge/c.md", "[[knowledge/a]]\n");
        let o = run(
            &p,
            &log,
            &[single("knowledge/a", "knowledge/z/a", false).unwrap()],
            true,
        )
        .unwrap();
        assert_eq!(o.rewritten, vec![("knowledge/c.md".to_string(), 1)]);
        assert!(root.join("knowledge/a.md").exists());
        assert_eq!(read(&root, "knowledge/c.md"), "[[knowledge/a]]\n");
    }
}
