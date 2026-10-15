//! `notes index` - scan `[[wikilinks]]` across permanent notes (zettels) and the curated
//! `knowledge/` tree, then report or rebuild the backlink + Map-of-Content (MOC) index. The
//! `scan` is shared with `doctor` for dead-link / orphan detection.

use crate::config::{self, Profile};
use crate::logging::Logger;
use anyhow::Result;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    /// `p.zettel`: flat, atomic, tag-grouped in the MOC.
    Zettel,
    /// `p.knowledge`: curated reference notes, grouped by subdir in the MOC.
    Knowledge,
}

pub struct Note {
    /// Lower-cased file stem: the key for collisions and resolution, never written as a link.
    pub stem: String,
    /// The `[[wikilink]]` body that names this note and no other. A zettel keeps its bare
    /// stem unless another scanned note shares it; a knowledge note always uses its
    /// root-relative path, because `notes.md`/`config.md` recur in nearly every subdir and a
    /// bare stem only has to be unique among scanned notes, not across the vault.
    pub link: String,
    pub path: PathBuf,
    pub kind: Kind,
    pub tags: Vec<String>,
    /// outbound link targets (normalised, see `extract_links`)
    pub links: Vec<String>,
}

pub struct Scan {
    pub notes: Vec<Note>,
    /// target link -> links of the notes that link to it
    pub backlinks: BTreeMap<String, Vec<String>>,
    /// (source_link, missing_target) pairs
    pub dead: Vec<(String, String)>,
    /// zettels with no inbound links. Knowledge notes are reached through their folder and the
    /// MOC, so a knowledge note nobody links to is normal, not a gap worth a doctor warning.
    pub orphans: Vec<String>,
}

/// Collect markdown files under `dir` as `(path, content)`, sorted by path. Recursive when
/// `deep`; dot-entries and `_log` dirs (the knowledge engine's logs, not notes) are skipped. A
/// missing dir yields nothing.
fn collect(dir: &Path, deep: bool) -> Result<Vec<(PathBuf, String)>> {
    let mut out = Vec::new();
    if !dir.exists() {
        return Ok(out);
    }
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let hidden = path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with('.'));
        if hidden || path.file_name().is_some_and(|n| n == "_log") {
            continue;
        }
        // `file_type` does not follow symlinks, so a linked dir cannot loop the walk.
        if entry.file_type()?.is_dir() {
            if deep {
                out.extend(collect(&path, true)?);
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
            let content = fs::read_to_string(&path).unwrap_or_default();
            out.push((path, content));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Extract `[[target]]` links from content, lower-cased, with any `|alias`, `#anchor` and
/// `.md` suffix removed. A path prefix is KEPT (`[[a/b]]` -> `a/b`) so `scan` can tell apart
/// notes that share a stem.
pub fn extract_links(content: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = content.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'[' && bytes[i + 1] == b'[' {
            if let Some(end) = content[i + 2..].find("]]") {
                let inner = &content[i + 2..i + 2 + end];
                let target = inner
                    .split('|')
                    .next()
                    .unwrap_or(inner)
                    .split('#')
                    .next()
                    .unwrap_or(inner)
                    .trim()
                    .trim_matches('/');
                let target = target.strip_suffix(".md").unwrap_or(target);
                if !target.is_empty() {
                    out.push(target.to_lowercase());
                }
                i = i + 2 + end + 2;
                continue;
            }
        }
        i += 1;
    }
    out
}

pub(crate) fn extract_tags(content: &str) -> Vec<String> {
    // crude frontmatter `tags: [a, b]` reader
    for line in content.lines().take(15) {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("tags:") {
            let rest = rest.trim().trim_start_matches('[').trim_end_matches(']');
            return rest
                .split(',')
                .map(|s| s.trim().trim_matches('"').to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
    }
    Vec::new()
}

/// Resolve a link `target` from note `src` to a note index. A target matches a note whose
/// root-relative path equals it or ends in `/<target>`. Several matches (a bare `[[notes]]`)
/// resolve to the one in the linking note's own directory, else the shortest path, ties
/// broken by path - deterministic, and close to how vault editors pick.
fn resolve(target: &str, src: usize, rels: &[String], notes: &[Note]) -> Option<usize> {
    let suffix = format!("/{target}");
    let candidates: Vec<usize> = (0..rels.len())
        .filter(|&i| rels[i] == target || rels[i].ends_with(&suffix))
        .collect();
    if candidates.len() <= 1 {
        return candidates.first().copied();
    }
    let src_dir = notes[src].path.parent();
    candidates
        .iter()
        .copied()
        .find(|&i| notes[i].path.parent() == src_dir)
        .or_else(|| {
            candidates
                .iter()
                .copied()
                .min_by(|&a, &b| (rels[a].len(), &rels[a]).cmp(&(rels[b].len(), &rels[b])))
        })
}

pub fn scan(p: &Profile) -> Result<Scan> {
    let mut raw: Vec<(Kind, PathBuf, String)> = Vec::new();
    for (path, content) in collect(&p.zettel, false)? {
        raw.push((Kind::Zettel, path, content));
    }
    for (path, content) in collect(&p.knowledge, true)? {
        // A custom `knowledge` dir set to (or above) `zettel` must not list a note twice.
        if !path.starts_with(&p.zettel) {
            raw.push((Kind::Knowledge, path, content));
        }
    }

    let stem_of = |path: &Path| {
        path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string()
    };
    let mut stem_count: HashMap<String, usize> = HashMap::new();
    for (_, path, _) in &raw {
        *stem_count.entry(stem_of(path).to_lowercase()).or_default() += 1;
    }

    let mut notes = Vec::new();
    for (kind, path, content) in raw {
        let stem = stem_of(&path).to_lowercase();
        // The link keeps the file's real case: `20260618T2221-x` must not become `...t2221-x`,
        // which opens nothing on a case-sensitive filesystem.
        let link = if kind == Kind::Zettel && stem_count[&stem] == 1 {
            stem_of(&path)
        } else {
            config::wikilink(&p.root, &path)
        };
        notes.push(Note {
            stem,
            link,
            tags: extract_tags(&content),
            links: extract_links(&content),
            path,
            kind,
        });
    }

    let rels: Vec<String> = notes
        .iter()
        .map(|n| config::wikilink(&p.root, &n.path).to_lowercase())
        .collect();
    let mut backlinks: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut dead = Vec::new();
    for (src, note) in notes.iter().enumerate() {
        for target in &note.links {
            match resolve(target, src, &rels, &notes) {
                Some(t) => backlinks
                    .entry(notes[t].link.clone())
                    .or_default()
                    .push(note.link.clone()),
                None => dead.push((note.link.clone(), target.clone())),
            }
        }
    }

    let orphans: Vec<String> = notes
        .iter()
        .filter(|n| n.kind == Kind::Zettel && !backlinks.contains_key(&n.link))
        .map(|n| n.link.clone())
        .collect();

    Ok(Scan {
        notes,
        backlinks,
        dead,
        orphans,
    })
}

/// One frontmatter field (`key: value`) from the first lines of `content`, quotes trimmed.
fn front_field(content: &str, key: &str) -> Option<String> {
    let body = content.strip_prefix("---\n")?;
    let end = body.find("\n---")?;
    body[..end].lines().find_map(|l| {
        let v = l
            .strip_prefix(key)?
            .strip_prefix(':')?
            .trim()
            .trim_matches('"');
        (!v.is_empty()).then(|| v.to_string())
    })
}

/// `## Knowledge`, one `### <subdir>` per directory under `p.knowledge` (top-level files
/// first), each note linked by path and labelled with its `title` (else its file stem). A
/// compiled article also shows its one-line `summary` and its tags, which makes the MOC the
/// catalog the knowledge engine reads first. Within a directory an INDEX/README leads, then the
/// rest by name. Empty when there are no knowledge notes.
fn render_knowledge(p: &Profile, notes: &[Note]) -> String {
    let mut by_dir: BTreeMap<(String, String), Vec<&Note>> = BTreeMap::new();
    for n in notes.iter().filter(|n| n.kind == Kind::Knowledge) {
        let dir = n
            .path
            .parent()
            .and_then(|d| d.strip_prefix(&p.knowledge).ok())
            .map(|d| d.to_string_lossy().into_owned())
            .unwrap_or_default();
        by_dir.entry((dir.to_lowercase(), dir)).or_default().push(n);
    }
    if by_dir.is_empty() {
        return String::new();
    }
    let mut out = String::from("## Knowledge\n\n");
    for ((_, dir), mut group) in by_dir {
        group.sort_by_key(|n| {
            (
                !matches!(n.stem.as_str(), "index" | "readme"),
                n.stem.clone(),
            )
        });
        let heading = if dir.is_empty() { "(top level)" } else { &dir };
        out.push_str(&format!("### {heading}\n"));
        for n in group {
            let content = fs::read_to_string(&n.path).unwrap_or_default();
            let stem = n.path.file_stem().unwrap_or_default().to_string_lossy();
            let label = front_field(&content, "title").unwrap_or_else(|| stem.into_owned());
            let mut line = format!("- [[{}|{label}]]", n.link);
            if let Some(summary) = front_field(&content, "summary") {
                line.push_str(&format!(" - {summary}"));
            }
            for tag in &n.tags {
                line.push_str(&format!(" #{tag}"));
            }
            out.push_str(&line);
            out.push('\n');
        }
        out.push('\n');
    }
    out
}

pub fn run(p: &Profile, log: &Logger, rebuild: bool) -> Result<()> {
    let s = scan(p)?;
    let zettels = s.notes.iter().filter(|n| n.kind == Kind::Zettel).count();
    println!(
        "permanent notes: {}  knowledge notes: {}  links resolved: {}  dead: {}  orphans: {}",
        zettels,
        s.notes.len() - zettels,
        s.backlinks.values().map(|v| v.len()).sum::<usize>(),
        s.dead.len(),
        s.orphans.len()
    );

    if !rebuild {
        return Ok(());
    }

    fs::create_dir_all(&p.index)?;

    // backlinks.md
    let mut bl = String::from("# Backlinks\n\n_Generated by `notes index --rebuild`._\n\n");
    for (target, sources) in &s.backlinks {
        bl.push_str(&format!("## [[{target}]]\n"));
        for src in sources {
            bl.push_str(&format!("- [[{src}]]\n"));
        }
        bl.push('\n');
    }
    fs::write(p.index.join("backlinks.md"), bl)?;

    // moc.md: zettels grouped by tag, then the knowledge tree grouped by subdir
    let mut by_tag: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for n in s.notes.iter().filter(|n| n.kind == Kind::Zettel) {
        if n.tags.is_empty() {
            by_tag
                .entry("untagged".to_string())
                .or_default()
                .push(n.link.clone());
        } else {
            for tag in &n.tags {
                by_tag.entry(tag.clone()).or_default().push(n.link.clone());
            }
        }
    }
    let mut moc = String::from("# Map of Content\n\n_Generated by `notes index --rebuild`._\n\n");
    for (tag, links) in &by_tag {
        moc.push_str(&format!("## #{tag}\n"));
        for link in links {
            moc.push_str(&format!("- [[{link}]]\n"));
        }
        moc.push('\n');
    }
    moc.push_str(&render_knowledge(p, &s.notes));
    fs::write(p.index.join("moc.md"), moc)?;

    log.info(
        "index",
        &format!(
            "rebuilt index ({} notes) at {}",
            s.notes.len(),
            p.index.display()
        ),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_extraction() {
        let c = "see [[foo]] and [[bar/baz|Baz]] and [[qux#section]] and [[x.md]]";
        let links = extract_links(c);
        assert_eq!(links, vec!["foo", "bar/baz", "qux", "x"]);
    }

    /// A throwaway vault under the temp dir, unique per test so parallel tests never share one.
    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-index-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(root: &Path, rel: &str, body: &str) {
        let path = root.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }

    /// Rebuild the index for `root` and return (moc.md, backlinks.md).
    fn rebuild(root: &Path) -> (String, String) {
        let p = crate::config::test_profile(root.to_str().unwrap());
        let log = Logger::new(root.join(".state/journal.log"), false);
        run(&p, &log, true).unwrap();
        (
            fs::read_to_string(p.index.join("moc.md")).unwrap(),
            fs::read_to_string(p.index.join("backlinks.md")).unwrap(),
        )
    }

    #[test]
    fn a_knowledge_note_is_listed_in_the_moc_under_its_subdir() {
        let root = vault("moc");
        write(
            &root,
            "journal/permanent/z1.md",
            "---\ntags: [idea]\n---\n# z1\n",
        );
        write(&root, "knowledge/brightsign/Players.md", "# players\n");
        write(&root, "knowledge/brightsign/manual.pdf", "not markdown");
        write(&root, "knowledge/top.md", "# top\n");

        let (moc, _) = rebuild(&root);

        assert!(moc.contains("## #idea\n- [[z1]]\n"), "{moc}");
        assert!(moc.contains("## Knowledge\n"), "{moc}");
        assert!(
            moc.contains("### brightsign\n- [[knowledge/brightsign/Players|Players]]\n"),
            "{moc}"
        );
        assert!(moc.contains("- [[knowledge/top|top]]\n"), "{moc}");
        assert!(
            !moc.contains("manual"),
            "non-markdown files are not notes: {moc}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_zettel_linking_a_knowledge_note_gives_it_a_backlink() {
        let root = vault("backlink");
        write(&root, "journal/permanent/z1.md", "see [[players]]\n");
        write(&root, "knowledge/brightsign/players.md", "# players\n");

        let (_, backlinks) = rebuild(&root);
        let s = scan(&crate::config::test_profile(root.to_str().unwrap())).unwrap();

        assert!(
            backlinks.contains("## [[knowledge/brightsign/players]]\n- [[z1]]\n"),
            "{backlinks}"
        );
        assert!(s.dead.is_empty(), "{:?}", s.dead);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_missing_knowledge_dir_is_fine() {
        let root = vault("noknowledge");
        write(&root, "journal/permanent/z1.md", "# z1\n");

        let (moc, _) = rebuild(&root);

        assert!(moc.contains("## #untagged\n- [[z1]]\n"), "{moc}");
        assert!(!moc.contains("## Knowledge"), "{moc}");
        let _ = fs::remove_dir_all(&root);
    }

    /// `notes.md` and `config.md` recur in nearly every knowledge subdir, and a zettel may share
    /// a stem with one. Every note must still be listed under a link that names it alone, and a
    /// bare `[[notes]]` resolves to the copy beside the linking note.
    #[test]
    fn colliding_stems_are_all_kept_and_resolve_deterministically() {
        let root = vault("collide");
        write(
            &root,
            "journal/permanent/notes.md",
            "# a zettel called notes\n",
        );
        write(&root, "knowledge/a/notes.md", "# a\n");
        write(&root, "knowledge/b/notes.md", "# b\n");
        write(&root, "knowledge/b/printer.md", "Related: [[notes]]\n");

        let (moc, backlinks) = rebuild(&root);

        assert!(moc.contains("- [[journal/permanent/notes]]\n"), "{moc}");
        assert!(
            moc.contains("### a\n- [[knowledge/a/notes|notes]]\n"),
            "{moc}"
        );
        assert!(moc.contains("- [[knowledge/b/notes|notes]]\n"), "{moc}");
        assert!(
            backlinks.contains("## [[knowledge/b/notes]]\n- [[knowledge/b/printer]]\n"),
            "{backlinks}"
        );
        assert!(
            !backlinks.contains("## [[knowledge/a/notes]]"),
            "{backlinks}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    /// Every link the MOC and backlinks write must open the file it names on a case-sensitive
    /// filesystem: zettel ids carry an uppercase `T`, and knowledge names keep their spaces.
    #[test]
    fn every_generated_link_resolves_case_sensitively() {
        let root = vault("case");
        write(
            &root,
            "journal/permanent/20260618T2221-an-idea.md",
            "---\ntags: [idea]\n---\nsee [[knowledge/sw/Hit List]]\n",
        );
        write(&root, "knowledge/sw/Hit List.md", "# hit list\n");

        let (moc, backlinks) = rebuild(&root);

        let mut checked = 0;
        for target in extract_links_raw(&moc)
            .into_iter()
            .chain(extract_links_raw(&backlinks))
        {
            let candidates = [
                root.join(format!("{target}.md")),
                root.join("journal/permanent").join(format!("{target}.md")),
            ];
            assert!(
                candidates.iter().any(|c| c.exists()),
                "[[{target}]] opens nothing:\n{moc}\n{backlinks}"
            );
            checked += 1;
        }
        assert!(checked >= 3, "too few links checked: {checked}");
        let _ = fs::remove_dir_all(&root);
    }

    /// `[[target]]` bodies with their case kept, alias and anchor dropped.
    fn extract_links_raw(content: &str) -> Vec<String> {
        content
            .split("[[")
            .skip(1)
            .filter_map(|r| r.split("]]").next())
            .map(|t| {
                t.split('|')
                    .next()
                    .unwrap()
                    .split('#')
                    .next()
                    .unwrap()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn a_compiled_article_shows_title_summary_and_tags_and_logs_are_not_notes() {
        let root = vault("catalog");
        write(
            &root,
            "knowledge/software/gw.md",
            "---\ntitle: LiteLLM gateway\nsummary: how models are routed\ntags: [software, reference]\n---\n# gw\n",
        );
        write(
            &root,
            "knowledge/_log/2026/10/2026-10-13.md",
            "- created [[knowledge/software/gw]]\n",
        );

        let (moc, _) = rebuild(&root);

        assert!(
            moc.contains(
                "- [[knowledge/software/gw|LiteLLM gateway]] - how models are routed #software #reference\n"
            ),
            "{moc}"
        );
        assert!(!moc.contains("_log"), "{moc}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn tag_extraction() {
        let c = "---\ntags: [idea, \"rust\"]\n---\n# t";
        assert_eq!(extract_tags(c), vec!["idea", "rust"]);
    }
}
