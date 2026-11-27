//! `notes projects <name> --json`: one project's knowledge space, the page the human opens to
//! see everything a project has in one place. This module owns the files (the lab dir's docs,
//! the repo's docs, ADRs and CHANGELOG head, the agent runtime's plans, lessons, sessions and
//! outcomes, and the knowledge notes that mention the project); the sheet's numbers come from
//! [`crate::projects::space_head`]. Open asks and queue items are not read here: their owners
//! are `agent-ask` and `agent-queue`, which `hub_core::space` joins in (one writer, one reader
//! per fact). Layout and field list: README "Projects", "The project page".

use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use anyhow::{bail, Result};
use serde::Serialize;
use serde_json::{json, Value};

use crate::config::{self, Profile};
use crate::projects;

/// The most entries any one list carries: a page, not a dump.
const CAP: usize = 60;

/// How many lines of the CHANGELOG the page carries.
const CHANGELOG_LINES: usize = 24;

/// One file in a list: its path from the list's root, its first heading and its mtime day.
#[derive(Debug, Serialize, PartialEq)]
pub(crate) struct Doc {
    pub path: String,
    pub title: String,
    pub modified: String,
}

/// A knowledge note that names the project, and why it matched: `path` (it sits under
/// `projects/<name>/`), `frontmatter` (a tag or project field) or `body` (a whole-word mention).
#[derive(Debug, Serialize, PartialEq)]
pub(crate) struct Note {
    pub path: String,
    pub title: String,
    pub why: &'static str,
}

fn day_of(path: &Path) -> String {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .and_then(|d| chrono::DateTime::from_timestamp(i64::try_from(d.as_secs()).ok()?, 0))
        .map(|t| t.with_timezone(&chrono::Local).date_naive().to_string())
        .unwrap_or_default()
}

/// A markdown file's first `# ` heading, else its stem.
fn heading(path: &Path, text: &str) -> String {
    text.lines()
        .find_map(|l| l.strip_prefix("# "))
        .map(|h| h.trim().to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| {
            path.file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
        })
}

/// Every `.md` under `root`, skipping hidden dirs and `node_modules`, sorted by path.
fn md_files(root: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let path = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == "node_modules" {
                continue;
            }
            match e.file_type() {
                Ok(t) if t.is_dir() && depth < 6 => walk(&path, out, depth + 1),
                Ok(t) if t.is_file() && name.ends_with(".md") => out.push(path),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    walk(root, &mut out, 0);
    out.sort();
    out
}

/// `root`'s markdown as a list, paths relative to `base`; `newest` orders by mtime, else by path.
fn docs(root: &Path, base: &Path, newest: bool) -> Vec<Doc> {
    let mut files = md_files(root);
    if newest {
        files.sort_by_key(|f| std::cmp::Reverse(fs::metadata(f).and_then(|m| m.modified()).ok()));
    }
    files
        .into_iter()
        .take(CAP)
        .map(|f| {
            let text = fs::read_to_string(&f).unwrap_or_default();
            Doc {
                path: f.strip_prefix(base).unwrap_or(&f).display().to_string(),
                title: heading(&f, &text),
                modified: day_of(&f),
            }
        })
        .collect()
}

/// True when `name` appears in `text` as a whole word (not inside a longer identifier).
fn whole_word(text: &str, name: &str) -> bool {
    let (text, name) = (text.to_lowercase(), name.to_lowercase());
    let ident = |c: char| c.is_alphanumeric() || c == '_' || c == '-';
    text.match_indices(&name).any(|(i, m)| {
        let before = text[..i].chars().next_back();
        let after = text[i + m.len()..].chars().next();
        !before.is_some_and(ident) && !after.is_some_and(ident)
    })
}

/// The knowledge notes of `p` that name the project, strongest reason first.
pub(crate) fn notes_naming(p: &Profile, name: &str) -> Vec<Note> {
    let under = format!("projects/{}/", name.to_lowercase());
    let mut found: Vec<Note> = crate::knowledge::articles(p)
        .into_iter()
        .filter_map(|file| {
            let text = fs::read_to_string(&file).ok()?;
            let rel = file.strip_prefix(&p.knowledge).unwrap_or(&file);
            let rel_s = rel.display().to_string();
            let fm = crate::knowledge::frontmatter(&text).unwrap_or_default();
            let why = if rel_s.to_lowercase().contains(&under) {
                "path"
            } else if fm
                .iter()
                .filter(|(k, _)| matches!(k.as_str(), "project" | "projects" | "tags"))
                .any(|(_, v)| whole_word(v, name))
            {
                "frontmatter"
            } else if whole_word(&text, name) {
                "body"
            } else {
                return None;
            };
            Some(Note {
                path: rel_s,
                title: crate::knowledge::title_of(&file, &text),
                why,
            })
        })
        .collect();
    let rank = |w: &str| ["path", "frontmatter", "body"].iter().position(|x| *x == w);
    found.sort_by(|a, b| rank(a.why).cmp(&rank(b.why)).then(a.path.cmp(&b.path)));
    found.truncate(CAP);
    found
}

/// The notes naming the project across every profile's knowledge store (the engine is one vault
/// today, so the stores are usually one dir): each distinct store is read once, the caller's first.
pub(crate) fn knowledge_naming(p: &Profile, name: &str) -> Vec<Note> {
    let mut seen = vec![p.knowledge.clone()];
    let mut found = notes_naming(p, name);
    for org in config::all_profile_names().unwrap_or_default() {
        let Ok(other) = config::resolve(Some(&org)) else {
            continue;
        };
        if seen.contains(&other.knowledge) || !other.knowledge.is_dir() {
            continue;
        }
        seen.push(other.knowledge.clone());
        found.extend(notes_naming(&other, name));
    }
    found.truncate(CAP);
    found
}

/// The first `CHANGELOG_LINES` lines of a repo's CHANGELOG.md, empty when it has none.
fn changelog_head(root: &Path) -> Vec<String> {
    fs::read_to_string(root.join("CHANGELOG.md"))
        .map(|t| {
            t.lines()
                .take(CHANGELOG_LINES)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// The repo half: its docs, its ADRs and the CHANGELOG head, from the registered checkout of
/// the project's repo (the tracker's `repo`, else the project's own key). Absent when the
/// project has no repo, or none is cloned here: a page with empty sections, never an error.
fn repo_part(reg: Option<&project_map::Registry>, name: &str) -> Value {
    let Some(reg) = reg else {
        return Value::Null;
    };
    let tracker = reg.tracker(name);
    let key = tracker
        .and_then(|t| t.get("repo"))
        .and_then(Value::as_str)
        .filter(|r| !r.is_empty())
        .unwrap_or(name);
    let Some(checkout) = reg.checkout(key) else {
        return Value::Null;
    };
    let root = match tracker.and_then(|t| t.get("path")).and_then(Value::as_str) {
        Some(sub) if !sub.is_empty() && checkout.join(sub).is_dir() => checkout.join(sub),
        _ => checkout.clone(),
    };
    let all = docs(&root.join("docs"), &root, false);
    let is_adr = |d: &Doc| {
        let p = d.path.to_lowercase();
        p.contains("/adr") || p.contains("/decisions/")
    };
    let (adrs, rest): (Vec<Doc>, Vec<Doc>) = all.into_iter().partition(is_adr);
    json!({
        "repo": key,
        "root": root,
        "readme": root.join("README.md").is_file(),
        "docs": rest,
        "adrs": adrs,
        "changelog_head": changelog_head(&root),
    })
}

/// The agent runtime's files for the project: `~/.agent/{plans,sessions,outcomes}/<name>/` and
/// `~/.agent/lessons/<name>.md`.
fn agent_part(name: &str) -> Value {
    let base = config::home().join(".agent");
    let listing = |kind: &str, newest: bool| -> Vec<Doc> {
        let root = base.join(kind).join(name);
        let mut files: Vec<PathBuf> = fs::read_dir(&root)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_file())
            .collect();
        files.sort_by_key(|f| std::cmp::Reverse(fs::metadata(f).and_then(|m| m.modified()).ok()));
        if !newest {
            files.sort();
        }
        files
            .into_iter()
            .take(CAP)
            .map(|f| {
                let text = if f.extension().and_then(|x| x.to_str()) == Some("md") {
                    fs::read_to_string(&f).unwrap_or_default()
                } else {
                    String::new()
                };
                Doc {
                    path: f.strip_prefix(&base).unwrap_or(&f).display().to_string(),
                    title: heading(&f, &text),
                    modified: day_of(&f),
                }
            })
            .collect()
    };
    let lessons = base.join("lessons").join(format!("{name}.md"));
    let lesson_text = fs::read_to_string(&lessons).unwrap_or_default();
    json!({
        "plans": listing("plans", true),
        "sessions": listing("sessions", true),
        "outcomes": listing("outcomes", true),
        "lessons": {
            "path": lessons.is_file().then(|| lessons.strip_prefix(&base).unwrap_or(&lessons).display().to_string()),
            "count": lesson_text.lines().filter(|l| l.starts_with("- ")).count(),
            "modified": day_of(&lessons),
        },
    })
}

/// The tracker link: the ticket system, the forge slugs and the URLs they open. The tickets
/// themselves stay in their tracker (`ticket`), never copied here.
fn tracker_part(reg: Option<&project_map::Registry>, name: &str) -> Value {
    let Some(t) = reg.and_then(|r| r.tracker(name)) else {
        return Value::Null;
    };
    let slug = |k: &str| t.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
    let forgejo_host = reg.and_then(|r| r.forge_host("forgejo"));
    let mut urls = Vec::new();
    if let Some(g) = slug("github") {
        urls.push(format!("https://github.com/{g}"));
    }
    if let (Some(f), Some(h)) = (slug("forgejo"), forgejo_host) {
        urls.push(format!("https://{h}/{f}"));
    }
    json!({
        "system": slug("system"),
        "github": slug("github"),
        "forgejo": slug("forgejo"),
        "urls": urls,
    })
}

/// The registry's wiring for the project, as the keys the readers use.
fn registry_part(reg: Option<&project_map::Registry>, name: &str) -> Value {
    let Some(reg) = reg else {
        return Value::Null;
    };
    let t = reg.tracker(name);
    let get = |k: &str| t.and_then(|t| t.get(k)).and_then(Value::as_str);
    json!({
        "type": reg.kind(name),
        "path": get("path"),
        "branch": get("branch"),
        "tag_glob": get("tagGlob"),
        "code": reg.code(name),
        "owner": get("owner"),
        "has_repo": reg.has_repo(name),
    })
}

/// The lab dir's own docs: the core files at its root, then everything under `docs/`.
fn lab_part(dir: &Path) -> Value {
    let core: Vec<Doc> = ["README.md", "summary.md", "ideas.md", "agent/README.md"]
        .iter()
        .map(|f| dir.join(f))
        .filter(|f| f.is_file())
        .map(|f| {
            let text = fs::read_to_string(&f).unwrap_or_default();
            Doc {
                path: f.strip_prefix(dir).unwrap_or(&f).display().to_string(),
                title: heading(&f, &text),
                modified: day_of(&f),
            }
        })
        .collect();
    json!({
        "dir": dir,
        "core": core,
        "docs": docs(&dir.join("docs"), dir, false),
        "versions": md_files(&dir.join("versions")).len(),
    })
}

/// `notes projects <name> --json`: the whole page, one object. Fails only for a name no
/// lab project resolves; every other source that is absent is `null` or an empty list.
pub fn print_or_bail(p: &Profile, name: Option<&str>) -> Result<()> {
    match name {
        Some(n) => print(p, n),
        None => bail!("--json goes with --stats, --roadmap, --sprints, or a project name"),
    }
}

fn print(p: &Profile, name: &str) -> Result<()> {
    let dir = projects::project_dir(p, name)?;
    let canonical = project_map::canonical(name.trim());
    let org = projects::project_org(p, name).unwrap_or_else(|| p.name.clone());
    let reg = project_map::cached();
    let reg = reg.as_deref();
    let Some(head) = projects::space_head(&org, &canonical, &dir)
        .as_object()
        .cloned()
    else {
        bail!("no page for '{name}'");
    };
    let mut page = serde_json::Map::new();
    page.insert("project".into(), json!(canonical));
    page.insert("profile".into(), json!(org));
    page.extend(head);
    page.insert("registry".into(), registry_part(reg, &canonical));
    page.insert("tracker".into(), tracker_part(reg, &canonical));
    page.insert("lab".into(), lab_part(&dir));
    page.insert("repo".into(), repo_part(reg, &canonical));
    page.insert("agent".into(), agent_part(&canonical));
    page.insert("knowledge".into(), json!(knowledge_naming(p, &canonical)));
    println!("{}", serde_json::to_string(&Value::Object(page))?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh empty dir under the system temp, named for the test.
    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("notes-space-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_name_matches_only_as_a_whole_word() {
        assert!(whole_word("the audio stack", "audio"));
        assert!(whole_word("Audio, again", "audio"));
        assert!(!whole_word("audiobook shelf", "audio"));
        assert!(!whole_word("my-audio-rig", "audio"));
        assert!(!whole_word("nothing here", "audio"));
    }

    #[test]
    fn docs_list_the_heading_and_skip_hidden_and_non_markdown() {
        let t = scratch("docs");
        fs::create_dir_all(t.join("docs/.hidden")).unwrap();
        fs::write(t.join("docs/a.md"), "# Alpha doc\nbody").unwrap();
        fs::write(t.join("docs/b.md"), "no heading").unwrap();
        fs::write(t.join("docs/c.txt"), "# not md").unwrap();
        fs::write(t.join("docs/.hidden/d.md"), "# hidden").unwrap();
        let got = docs(&t.join("docs"), &t, false);
        let seen: Vec<(&str, &str)> = got
            .iter()
            .map(|d| (d.path.as_str(), d.title.as_str()))
            .collect();
        assert_eq!(seen, [("docs/a.md", "Alpha doc"), ("docs/b.md", "b")]);
    }

    #[test]
    fn a_missing_docs_dir_is_an_empty_list_not_an_error() {
        let t = scratch("missing");
        assert!(docs(&t.join("nope"), &t, false).is_empty());
        assert!(changelog_head(&t).is_empty());
    }

    #[test]
    fn the_changelog_head_is_capped() {
        let t = scratch("changelog");
        let body: String = (0..100).map(|i| format!("line {i}\n")).collect();
        fs::write(t.join("CHANGELOG.md"), body).unwrap();
        assert_eq!(changelog_head(&t).len(), CHANGELOG_LINES);
    }
}
