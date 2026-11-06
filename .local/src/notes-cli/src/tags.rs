//! `notes tags` — scan the vault for inline `#hashtags` + frontmatter `tags:` and
//! either list every tag with a count or show every line carrying a given tag.
//!
//! Read-only and on-demand: unlike `notes index`, nothing is written and there is no
//! index file to go stale. The scanned dirs are `Profile::tag_scan` (config), read whole, and
//! every profile's project dir, where only task rows count: lab docs are prose full of `#if`.

use crate::config::Profile;
use crate::daily::all_project_dirs;
use crate::index::extract_tags;
use crate::md::{self, TagKind};
use anyhow::Result;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// A single tag occurrence: which file, which 1-based line, and the line's text.
struct Hit {
    tag: String,
    path: PathBuf,
    line: usize,
    text: String,
}

/// Recursively collect `.md` files under `dir`, skipping hidden dirs (e.g. `.git`).
/// A missing dir is silently ignored (like `index::collect`), so an unset/partial
/// profile never panics.
fn collect_md(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let hidden = path
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.starts_with('.'));
            if !hidden {
                collect_md(&path, out);
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
            out.push(path);
        }
    }
}

/// Extract every tag occurrence from one file: frontmatter tags are attributed to the
/// `tags:` line; inline `#hashtags` to their own line. `rows_only` keeps task rows alone.
fn scan_file(path: &Path, rows_only: bool, out: &mut Vec<Hit>) {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    if !rows_only {
        let fm_tags = extract_tags(&content);
        if !fm_tags.is_empty() {
            for (idx, line) in content.lines().take(15).enumerate() {
                if line.trim_start().starts_with("tags:") {
                    for t in &fm_tags {
                        out.push(Hit {
                            tag: t.to_lowercase(),
                            path: path.to_path_buf(),
                            line: idx + 1,
                            text: line.trim().to_string(),
                        });
                    }
                    break;
                }
            }
        }
    }

    for (idx, line) in content.lines().enumerate() {
        if rows_only && !md::is_task(line) {
            continue;
        }
        for t in md::find_hashtags(line) {
            out.push(Hit {
                tag: t,
                path: path.to_path_buf(),
                line: idx + 1,
                text: line.trim().to_string(),
            });
        }
    }
}

/// All tag occurrences in `prose` dirs, read whole, and `boards` dirs, read for task rows. A
/// file under both is read once, whole.
fn scan(prose: &[PathBuf], boards: &[PathBuf]) -> Vec<Hit> {
    let mut rows_only = BTreeMap::new();
    for (dirs, rows) in [(boards, true), (prose, false)] {
        let mut files = Vec::new();
        for dir in dirs {
            collect_md(dir, &mut files);
        }
        rows_only.extend(files.into_iter().map(|f| (f, rows)));
    }
    let mut hits = Vec::new();
    for (f, rows) in &rows_only {
        scan_file(f, *rows, &mut hits);
    }
    hits
}

/// The profile's prose dirs plus every profile's projects: most rows live outside the active one.
fn all_hits(p: &Profile) -> Vec<Hit> {
    let boards: Vec<PathBuf> = all_project_dirs().into_iter().map(|(_, d)| d).collect();
    scan(&p.tag_scan, &boards)
}

/// Tags with their counts, topics before task tags and most-used first within each (ties by
/// name), so row state like `#high` cannot bury the topics. `only` keeps one kind.
fn ranked(hits: &[Hit], only: Option<TagKind>) -> Vec<(String, usize)> {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    // Created and due tags (`#c1026`, `#due1031`) are dates, one per day: counted here they
    // would bury every real tag. `notes tags c1026` still finds a day's tasks, `rg '#c10'` a month's.
    for h in hits {
        let t = h.tag.trim_start_matches('#');
        if !md::is_created_tag(t) && !md::is_due_tag(t) {
            *counts.entry(&h.tag).or_default() += 1;
        }
    }
    let mut rows: Vec<_> = counts
        .into_iter()
        .map(|(t, n)| {
            let kind = md::tag_kind(t.trim_start_matches('#'));
            (kind, std::cmp::Reverse(n), t)
        })
        .filter(|(k, ..)| only.is_none_or(|o| o == *k))
        .collect();
    rows.sort();
    rows.into_iter()
        .map(|(_, n, t)| (t.to_string(), n.0))
        .collect()
}

/// `notes tags [--kind task|topic]` - print `"<tag>\t<count>"` in [`ranked`] order.
pub fn list(p: &Profile, only: Option<TagKind>) -> Result<()> {
    for (tag, count) in ranked(&all_hits(p), only) {
        println!("{tag}\t{count}");
    }
    Ok(())
}

/// `notes tags <name>` — print `"<path>\t<line>\t<text>"` for every matching line.
/// A leading `#` on the query is optional; matching is case-insensitive.
pub fn show(p: &Profile, name: &str) -> Result<()> {
    let want = name.trim_start_matches('#').to_lowercase();
    for h in &all_hits(p) {
        if h.tag == want {
            println!("{}\t{}\t{}", h.path.display(), h.line, h.text);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault(name: &str, files: &[(&str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("notes-tags-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (path, body) in files {
            let f = root.join(path);
            fs::create_dir_all(f.parent().unwrap()).unwrap();
            fs::write(f, body).unwrap();
        }
        root
    }

    #[test]
    fn a_board_counts_its_task_rows_and_not_its_prose() {
        let root = vault(
            "rows",
            &[
                ("notes/a.md", "---\ntags: [software]\n---\nsome #prose here\n"),
                (
                    "board/README.md",
                    "---\ntags: [skipped]\n---\nVersion: v0.1.0 #alpha\nCSS #fff in prose\n- [ ] do it #size/s #high\n  detail #detail\n- [x] done #requested\n",
                ),
            ],
        );
        let hits = scan(&[root.join("notes")], &[root.join("board")]);
        let tags: Vec<&str> = hits.iter().map(|h| h.tag.as_str()).collect();
        assert_eq!(tags, ["size/s", "high", "requested", "software", "prose"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_file_in_both_scans_is_read_once_and_whole() {
        let root = vault("both", &[("d/a.md", "prose #one\n- [ ] row #two\n")]);
        let dirs = [root.join("d")];
        let tags: Vec<String> = scan(&dirs, &dirs).into_iter().map(|h| h.tag).collect();
        assert_eq!(tags, ["one", "two"]);
        fs::remove_dir_all(root).unwrap();
    }

    fn hit(tag: &str) -> Hit {
        Hit {
            tag: tag.to_string(),
            path: PathBuf::new(),
            line: 1,
            text: String::new(),
        }
    }

    #[test]
    fn topics_list_before_task_tags_however_common_those_are() {
        let hits: Vec<Hit> = [
            "high", "high", "high", "ai", "software", "software", "c1026", "due1031",
        ]
        .into_iter()
        .map(hit)
        .collect();
        let names =
            |only| -> Vec<String> { ranked(&hits, only).into_iter().map(|(t, _)| t).collect() };
        assert_eq!(names(None), ["software", "ai", "high"]);
        assert_eq!(names(Some(TagKind::Task)), ["high"]);
        assert_eq!(names(Some(TagKind::Topic)), ["software", "ai"]);
    }
}
