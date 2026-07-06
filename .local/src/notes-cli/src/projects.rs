//! `notes projects` — the indexed projects that back the daily note's `## Current
//! Projects` block, exposed for a picker. No arg lists every project as
//! `name<TAB>summary-path<TAB>status`; `<name>` lists that project's note files as
//! `path<TAB>label` (summary first) for a drill-down.
//!
//! Read-only and on-demand, exactly like `notes tags`: nothing is written and there
//! is no index file to go stale. Discovery mirrors `notes today`'s precedence — the
//! project index `## Current` lane, else the `projects` dir scan (`daily`).

use crate::config::Profile;
use crate::daily;
use crate::md;
use anyhow::Result;
use std::fs;
use std::path::{Path, PathBuf};

/// `(name, summary_path)` for every indexed project, mirroring `notes today`'s
/// precedence: the project index `## Current` lane, else the `projects` dir scan.
fn indexed(p: &Profile) -> Vec<(String, PathBuf)> {
    match from_index(p) {
        Some(list) if !list.is_empty() => list,
        _ => daily::discover_project_dirs(p),
    }
}

/// Parse the `## Current` lane of the project index into `(name, summary_path)` pairs.
/// Each entry is a wikilink `[[<target>|<name>]]` (alias optional) with a vault-root-
/// relative `<target>`, so the path is `root/<target>.md`. Blank / placeholder lines
/// are skipped. `None` when the index is unset/absent or the lane has no entries.
fn from_index(p: &Profile) -> Option<Vec<(String, PathBuf)>> {
    let idx = p.project_index.as_ref()?;
    let content = fs::read_to_string(idx).ok()?;
    let lines = md::section_lines(&content, "Current")?;
    let mut out = Vec::new();
    for l in lines {
        let t = l.trim();
        if t.is_empty() || t == "-" || (t.starts_with('_') && t.ends_with('_')) {
            continue;
        }
        if let Some((target, name)) = parse_wikilink(t) {
            let mut path = p.root.join(&target);
            if path.extension().is_none() {
                path.set_extension("md");
            }
            out.push((name, path));
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Extract `(target, name)` from a line containing `[[target|name]]` (or bare
/// `[[target]]`). Without an explicit alias the name is the target's last path
/// segment — and when that segment is the generic `summary`, its parent dir instead
/// (so `[[…/placemyparents/summary]]` still names the project `placemyparents`).
fn parse_wikilink(line: &str) -> Option<(String, String)> {
    let start = line.find("[[")? + 2;
    let end = line[start..].find("]]")? + start;
    let inner = &line[start..end];
    let (target, name) = match inner.split_once('|') {
        Some((t, n)) => (t.trim().to_string(), n.trim().to_string()),
        None => {
            let t = inner.trim().trim_end_matches(".md").to_string();
            let segs: Vec<&str> = t.split('/').filter(|s| !s.is_empty()).collect();
            let name = match segs.as_slice() {
                [.., parent, "summary"] => parent.to_string(),
                [.., last] => last.to_string(),
                [] => t.clone(),
            };
            (t, name)
        }
    };
    Some((target, name))
}

/// `notes projects` — print `"<name>\t<summary-path>\t<status>"` per indexed project.
/// `<status>` is the agent-written note in the summary's `STATUS:START`/`STATUS:END`
/// block (empty when unwritten — the `_(no status yet)_` placeholder counts as empty).
pub fn list(p: &Profile) -> Result<()> {
    for (name, summary) in indexed(p) {
        let status = fs::read_to_string(&summary)
            .ok()
            .and_then(|c| status_line(&c))
            .unwrap_or_default();
        println!("{}\t{}\t{}", name, summary.display(), status);
    }
    Ok(())
}

/// First real line of the summary's `<!-- STATUS:START --> … <!-- STATUS:END -->`
/// block — the agent-written "where we are" note. Skips blank / comment / italic
/// placeholder (`_(…)_`) lines. `None` when the block is absent or unwritten.
fn status_line(content: &str) -> Option<String> {
    let mut in_block = false;
    for line in content.lines() {
        let t = line.trim();
        if t.contains("STATUS:START") {
            in_block = true;
            continue;
        }
        if t.contains("STATUS:END") {
            break;
        }
        if !in_block || t.is_empty() || is_comment(t) || is_placeholder(t) {
            continue;
        }
        return Some(t.replace('\t', " "));
    }
    None
}

fn is_comment(t: &str) -> bool {
    t.starts_with("<!--")
}

/// An italic placeholder like `_(no status yet)_` or `_(nothing yet)_`.
fn is_placeholder(t: &str) -> bool {
    t.starts_with('_') && t.ends_with('_')
}

/// `notes projects <name>` — print `"<path>\t<label>"` for each note file in the
/// project (summary first, then version notes / changelog / others by label). The
/// name match is case-insensitive.
pub fn show(p: &Profile, name: &str) -> Result<()> {
    let want = name.to_lowercase();
    let Some((_, summary)) = indexed(p).into_iter().find(|(n, _)| n.to_lowercase() == want) else {
        eprintln!("no indexed project named '{name}'");
        return Ok(());
    };
    let Some(dir) = summary.parent() else {
        return Ok(());
    };

    let mut files: Vec<(PathBuf, String)> = Vec::new();
    collect_project_files(dir, &mut files);
    // `summary` floats to the top; the rest sort by label.
    files.sort_by(|a, b| (a.1 != "summary", &a.1).cmp(&(b.1 != "summary", &b.1)));
    for (path, label) in files {
        println!("{}\t{}", path.display(), label);
    }
    Ok(())
}

/// Collect a project's note files: top-level `.md` files (label = file stem) plus one
/// level into a `changelog/` dir (label = `changelog/<stem>`).
fn collect_project_files(dir: &Path, out: &mut Vec<(PathBuf, String)>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().and_then(|n| n.to_str()) == Some("changelog") {
                if let Ok(sub) = fs::read_dir(&path) {
                    for e in sub.flatten() {
                        let sp = e.path();
                        if sp.extension().and_then(|x| x.to_str()) == Some("md") {
                            let stem = sp.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                            out.push((sp.clone(), format!("changelog/{stem}")));
                        }
                    }
                }
            }
        } else if path.extension().and_then(|x| x.to_str()) == Some("md") {
            let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
            out.push((path, stem));
        }
    }
}
