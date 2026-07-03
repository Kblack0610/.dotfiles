//! `notes tags` — scan the vault for inline `#hashtags` + frontmatter `tags:` and
//! either list every tag with a count or show every line carrying a given tag.
//!
//! Read-only and on-demand: unlike `notes index`, nothing is written and there is no
//! index file to go stale. The set of scanned dirs is `Profile::tag_scan` (config).

use crate::config::Profile;
use crate::index::extract_tags;
use crate::md;
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
/// `tags:` line; inline `#hashtags` to their own line.
fn scan_file(path: &Path, out: &mut Vec<Hit>) {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return,
    };

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

    for (idx, line) in content.lines().enumerate() {
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

/// All tag occurrences across the profile's scanned dirs.
fn all_hits(p: &Profile) -> Vec<Hit> {
    let mut files = Vec::new();
    for dir in &p.tag_scan {
        collect_md(dir, &mut files);
    }
    files.sort();
    files.dedup();

    let mut hits = Vec::new();
    for f in &files {
        scan_file(f, &mut hits);
    }
    hits
}

/// `notes tags` — print `"<tag>\t<count>"`, most-used first (ties broken by name).
pub fn list(p: &Profile) -> Result<()> {
    let hits = all_hits(p);
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for h in &hits {
        *counts.entry(h.tag.clone()).or_default() += 1;
    }
    let mut rows: Vec<(&String, &usize)> = counts.iter().collect();
    rows.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    for (tag, count) in rows {
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
