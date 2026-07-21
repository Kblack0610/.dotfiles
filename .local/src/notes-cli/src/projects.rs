//! `notes projects` — the indexed projects that back the daily note's `## Current
//! Projects` block, exposed for a picker. No arg lists every project as
//! `name<TAB>summary-path<TAB>status`; `<name>` lists that project's note files as
//! `path<TAB>label` (summary first) for a drill-down.
//!
//! Read-only and on-demand, exactly like `notes tags`: nothing is written and there
//! is no index file to go stale. Discovery mirrors `notes today`'s precedence — the
//! project index `## Current` lane, else the `projects` dir scan (`daily`).

use crate::config::{self, Profile};
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
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
/// (so `[[…/myapp/summary]]` still names the project `myapp`).
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
    let Some((_, summary)) = indexed(p)
        .into_iter()
        .find(|(n, _)| n.to_lowercase() == want)
    else {
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

// ── lifecycle: create / archive / restore ───────────────────────────────────
//
// A project is a DIR holding `summary.md` plus an entry in the matching lane of the
// project index (`lab/projects/index.md`). The index's own note says "move a project
// between the lanes to change its status", so these verbs keep the two in lockstep:
// `current/<name>` <-> `## Current` and `archived/<name>` <-> `## Archived`.

/// The `archived/` sibling of the current-projects dir.
fn archived_dir(p: &Profile) -> Option<PathBuf> {
    p.projects.as_ref()?.parent().map(|d| d.join("archived"))
}

/// `- [[<vault-relative target>|<name>]]` — the index lane entry for a summary file.
fn lane_line(p: &Profile, summary: &Path, name: &str) -> String {
    format!("- [[{}|{}]]", config::wikilink(&p.root, summary), name)
}

/// Real (non-placeholder) entries in a lane.
fn lane_entries(content: &str, heading: &str) -> Vec<String> {
    md::section_lines(content, heading)
        .unwrap_or_default()
        .into_iter()
        .filter(|l| {
            let t = l.trim();
            !t.is_empty() && t != "-" && !(t.starts_with('_') && t.ends_with('_'))
        })
        .collect()
}

/// Drop a lane's `_(nothing yet)_` placeholder — called before inserting a real entry.
fn strip_lane_placeholder(content: &str, heading: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut in_lane = false;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            in_lane = rest.trim().eq_ignore_ascii_case(heading);
            out.push(line.to_string());
            continue;
        }
        let t = line.trim();
        if in_lane && t.starts_with('_') && t.ends_with('_') && !t.is_empty() {
            continue; // placeholder — drop
        }
        out.push(line.to_string());
    }
    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

/// Re-add `_(nothing yet)_` when a lane has been emptied, so the hub reads cleanly.
fn ensure_lane_placeholder(content: &str, heading: &str) -> String {
    if !lane_entries(content, heading).is_empty() {
        return content.to_string();
    }
    md::insert_under_heading(content, heading, &["_(nothing yet)_".to_string()])
}

/// Remove the first entry naming `name` from the `## heading` lane.
/// `None` when the lane has no such entry.
fn remove_from_lane(content: &str, heading: &str, name: &str) -> Option<String> {
    let want = name.to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut in_lane = false;
    let mut removed = false;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            in_lane = rest.trim().eq_ignore_ascii_case(heading);
            out.push(line.to_string());
            continue;
        }
        if in_lane && !removed {
            if let Some((_, n)) = parse_wikilink(line) {
                if n.to_lowercase() == want {
                    removed = true;
                    continue; // drop the entry
                }
            }
        }
        out.push(line.to_string());
    }
    if !removed {
        return None;
    }
    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    Some(joined)
}

/// Move a project's index entry from one lane to another (rewriting its link target).
fn move_lane(p: &Profile, from: &str, to: &str, name: &str, new_summary: &Path) -> Result<()> {
    let Some(idx) = &p.project_index else {
        return Ok(()); // no index configured — the dir move is the whole story
    };
    let content = fs::read_to_string(idx).unwrap_or_default();
    let content = remove_from_lane(&content, from, name).unwrap_or(content);
    let content = ensure_lane_placeholder(&content, from);
    let content = strip_lane_placeholder(&content, to);
    let content = md::insert_under_heading(&content, to, &[lane_line(p, new_summary, name)]);
    fs::write(idx, content)?;
    Ok(())
}

/// Reject names that would escape the projects dir or collide with the index.
fn check_name(name: &str) -> Result<()> {
    if name.is_empty() || name.contains('/') || name.starts_with('.') || name == "index" {
        bail!("invalid project name '{name}' (no slashes / leading dot)");
    }
    Ok(())
}

/// Scaffold for a new `summary.md`. Mirrors the existing lab convention exactly — the
/// `## → For the agents` heading and the STATUS/AUTO markers are load-bearing (the
/// session preflight and lab-sync grep for them), so they are reproduced verbatim.
fn summary_template(name: &str) -> String {
    format!(
        "---\nid: summary\naliases: []\ntags: []\n---\n\n# {name}\n<!-- canonical: {name} -->\n\n\
## → For the agents\n\
_Type wants / tasks / direction here — read at session start (preflight injects it). \
Agents scope each into a ticket, which then surfaces in the cockpit below. \
lab-sync never edits this section._\n- _(nothing yet — type a want)_\n\n\
## Reference\n_(what this project is)_\n\n\
<!-- STATUS:START — an agent writes a dated \"where we are\" note here; do not hand-edit -->\n\
_(no status yet)_\n<!-- STATUS:END -->\n\n\
<!-- AUTO:START — maintained by /lab-sync (regen-lab-feed.sh); edits below are overwritten -->\n\
## ← Release & status feed\n_(run /lab-sync to populate)_\n<!-- AUTO:END -->\n"
    )
}

/// `notes projects --new <name>` — scaffold `current/<name>/summary.md` and add it to
/// the index's `## Current` lane. Prints the new summary path.
pub fn new_project(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let name = name.trim();
    check_name(name)?;
    let Some(dir_root) = p.projects.as_ref() else {
        bail!("this profile has no `projects` dir configured");
    };
    let dir = dir_root.join(name);
    if dir.exists() {
        bail!("project '{name}' already exists at {}", dir.display());
    }
    fs::create_dir_all(&dir)?;
    let summary = dir.join("summary.md");
    fs::write(&summary, summary_template(name))?;
    // every lab project is version-based and starts at v0.0.1
    write_version_note(&dir, "v0.0.1")?;

    if let Some(idx) = &p.project_index {
        let content = fs::read_to_string(idx).unwrap_or_default();
        let content = strip_lane_placeholder(&content, "Current");
        let content = md::insert_under_heading(&content, "Current", &[lane_line(p, &summary, name)]);
        fs::write(idx, content)?;
    }
    log.info("projects", &format!("created {}", dir.display()));
    println!("{}", summary.display());
    Ok(())
}

/// `notes projects --archive <name>` — move `current/<name>` to `archived/<name>` and
/// move its index entry from `## Current` to `## Archived`.
pub fn archive(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let name = name.trim();
    check_name(name)?;
    let Some(cur_root) = p.projects.as_ref() else {
        bail!("this profile has no `projects` dir configured");
    };
    let src = cur_root.join(name);
    if !src.is_dir() {
        bail!("no current project named '{name}'");
    }
    let Some(arch_root) = archived_dir(p) else {
        bail!("cannot resolve the archived/ dir");
    };
    fs::create_dir_all(&arch_root)?;
    let dest = arch_root.join(name);
    if dest.exists() {
        bail!("'{name}' is already archived at {}", dest.display());
    }
    fs::rename(&src, &dest)?;
    move_lane(p, "Current", "Archived", name, &dest.join("summary.md"))?;
    log.info("projects", &format!("archived {name}"));
    println!("archived {name} -> {}", dest.display());
    Ok(())
}

/// `notes projects --restore <name>` — the inverse of `archive`: pull an archived
/// project back into `current/` and the `## Current` lane.
pub fn restore(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let name = name.trim();
    check_name(name)?;
    let Some(cur_root) = p.projects.as_ref() else {
        bail!("this profile has no `projects` dir configured");
    };
    let Some(arch_root) = archived_dir(p) else {
        bail!("cannot resolve the archived/ dir");
    };
    let src = arch_root.join(name);
    if !src.is_dir() {
        bail!("no archived project named '{name}'");
    }
    let dest = cur_root.join(name);
    if dest.exists() {
        bail!("'{name}' already exists in current/");
    }
    fs::create_dir_all(cur_root)?;
    fs::rename(&src, &dest)?;
    move_lane(p, "Archived", "Current", name, &dest.join("summary.md"))?;
    log.info("projects", &format!("restored {name}"));
    println!("restored {name} -> {}", dest.display());
    Ok(())
}

// ── versions ────────────────────────────────────────────────────────────────
//
// Every lab project is version-based and starts at v0.0.1. A version is a
// `vX.Y.Z.md` note holding that release's task list — the third level of the
// projects hub ("a vX.Y.Z.md file — deep detail for one release").

/// How far to bump: `v0.1.2` -> patch `v0.1.3`, minor `v0.2.0`, major `v1.0.0`.
#[derive(Clone, Copy)]
pub enum Bump {
    Patch,
    Minor,
    Major,
}

/// Parse `vX.Y.Z` from a file stem. `None` when it isn't a version note.
fn parse_version(stem: &str) -> Option<(u32, u32, u32)> {
    let rest = stem.strip_prefix('v')?;
    let mut it = rest.split('.');
    let v = (
        it.next()?.parse().ok()?,
        it.next()?.parse().ok()?,
        it.next()?.parse().ok()?,
    );
    if it.next().is_some() {
        return None;
    }
    Some(v)
}

fn fmt_version(v: (u32, u32, u32)) -> String {
    format!("v{}.{}.{}", v.0, v.1, v.2)
}

fn scan_versions(dir: &Path, best: &mut Option<(u32, u32, u32)>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let path = e.path();
        if path.extension().and_then(|x| x.to_str()) != Some("md") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if let Some(v) = parse_version(stem) {
            if best.is_none_or(|b| v > b) {
                *best = Some(v);
            }
        }
    }
}

/// Highest version note in a project — its root plus a `changelog/` subdir.
fn current_version(dir: &Path) -> Option<(u32, u32, u32)> {
    let mut best = None;
    scan_versions(dir, &mut best);
    scan_versions(&dir.join("changelog"), &mut best);
    best
}

/// The next version after `cur` (or the v0.0.1 seed when the project has none).
fn next_version(cur: Option<(u32, u32, u32)>, level: Bump) -> (u32, u32, u32) {
    match cur {
        None => (0, 0, 1), // every lab project starts here
        Some((a, b, c)) => match level {
            Bump::Patch => (a, b, c + 1),
            Bump::Minor => (a, b + 1, 0),
            Bump::Major => (a + 1, 0, 0),
        },
    }
}

/// New version notes land in `changelog/` when the project keeps one, else at its root
/// — so each project's existing layout is preserved.
fn version_dir(project_dir: &Path) -> PathBuf {
    let cl = project_dir.join("changelog");
    if cl.is_dir() {
        cl
    } else {
        project_dir.to_path_buf()
    }
}

/// A version note: frontmatter + an open task line, matching the existing convention.
fn version_template(ver: &str) -> String {
    format!("---\nid: {ver}\naliases: []\ntags: []\n---\n\n- [ ] \n")
}

fn write_version_note(project_dir: &Path, ver: &str) -> Result<PathBuf> {
    let dir = version_dir(project_dir);
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{ver}.md"));
    if path.exists() {
        bail!("{} already exists", path.display());
    }
    fs::write(&path, version_template(ver))?;
    Ok(path)
}

/// Resolve a current project's directory by name (case-insensitive).
fn project_dir(p: &Profile, name: &str) -> Result<PathBuf> {
    let want = name.trim().to_lowercase();
    let Some((_, summary)) = indexed(p).into_iter().find(|(n, _)| n.to_lowercase() == want) else {
        bail!("no current project named '{name}'");
    };
    summary
        .parent()
        .map(|d| d.to_path_buf())
        .ok_or_else(|| anyhow::anyhow!("cannot resolve the project dir for '{name}'"))
}

/// `notes projects --bump <name>` — start the next version's note so you can scope
/// tasks into it. A project with no version yet is seeded at v0.0.1.
pub fn bump(p: &Profile, log: &Logger, name: &str, level: Bump) -> Result<()> {
    let dir = project_dir(p, name)?;
    let ver = fmt_version(next_version(current_version(&dir), level));
    let path = write_version_note(&dir, &ver)?;
    log.info("projects", &format!("{name} -> {ver}"));
    println!("{}", path.display());
    Ok(())
}

/// `notes projects --version-of <name>` — print the project's current version (empty
/// when it has none yet), for pickers/status lines.
pub fn show_version(p: &Profile, name: &str) -> Result<()> {
    let dir = project_dir(p, name)?;
    if let Some(v) = current_version(&dir) {
        println!("{}", fmt_version(v));
    }
    Ok(())
}

/// `notes projects --archived` — list archived projects in the same
/// `name<TAB>summary<TAB>status` shape as `list`, so a picker can restore from it.
pub fn list_archived(p: &Profile) -> Result<()> {
    let Some(root) = archived_dir(p) else {
        return Ok(());
    };
    let Ok(entries) = fs::read_dir(&root) else {
        return Ok(());
    };
    let mut names: Vec<(String, PathBuf)> = Vec::new();
    for e in entries.flatten() {
        let dir = e.path();
        if !dir.is_dir() {
            continue;
        }
        let summary = dir.join("summary.md");
        if summary.exists() {
            let name = dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            if !name.is_empty() && !name.starts_with('_') {
                names.push((name, summary));
            }
        }
    }
    names.sort();
    for (name, summary) in names {
        let status = fs::read_to_string(&summary)
            .ok()
            .and_then(|c| status_line(&c))
            .unwrap_or_default();
        println!("{}\t{}\t{}", name, summary.display(), status);
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
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            out.push((path, stem));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INDEX: &str = "\
# Projects

## Current
- [[lab/projects/current/alpha/summary|alpha]]
- [[lab/projects/current/beta/summary|beta]]

## Archived
- [[lab/projects/archived/old/summary|old]]

## Backlog
_(nothing yet)_
";

    #[test]
    fn removes_named_entry_from_its_lane_only() {
        let out = remove_from_lane(INDEX, "Current", "alpha").unwrap();
        assert!(!out.contains("|alpha]]"));
        // sibling entry and the other lane are untouched
        assert!(out.contains("|beta]]"));
        assert!(out.contains("|old]]"));
    }

    #[test]
    fn remove_is_none_when_entry_absent() {
        assert!(remove_from_lane(INDEX, "Current", "nope").is_none());
        // right name, wrong lane -> not removed from that lane
        assert!(remove_from_lane(INDEX, "Archived", "alpha").is_none());
    }

    #[test]
    fn emptied_lane_regains_its_placeholder() {
        let out = remove_from_lane(INDEX, "Archived", "old").unwrap();
        let out = ensure_lane_placeholder(&out, "Archived");
        assert!(lane_entries(&out, "Archived").is_empty());
        assert!(out.contains("_(nothing yet)_"));
        // a lane that still has entries is left alone
        let same = ensure_lane_placeholder(&out, "Current");
        assert_eq!(lane_entries(&same, "Current").len(), 2);
    }

    #[test]
    fn placeholder_is_stripped_before_a_real_entry_lands() {
        let out = strip_lane_placeholder(INDEX, "Backlog");
        assert!(lane_entries(&out, "Backlog").is_empty());
        // only the Backlog placeholder went; other lanes keep their entries
        assert!(out.contains("|alpha]]") && out.contains("|old]]"));
    }

    #[test]
    fn rejects_names_that_escape_the_projects_dir() {
        assert!(check_name("../etc").is_err());
        assert!(check_name(".hidden").is_err());
        assert!(check_name("").is_err());
        assert!(check_name("index").is_err());
        assert!(check_name("my-app").is_ok());
    }

    #[test]
    fn parses_only_real_version_stems() {
        assert_eq!(parse_version("v1.8.0"), Some((1, 8, 0)));
        assert_eq!(parse_version("v0.0.1"), Some((0, 0, 1)));
        assert_eq!(parse_version("summary"), None);
        assert_eq!(parse_version("v1.8"), None); // not three parts
        assert_eq!(parse_version("v1.8.0.1"), None);
        assert_eq!(parse_version("1.8.0"), None); // missing the v
    }

    #[test]
    fn version_less_project_seeds_at_v0_0_1() {
        assert_eq!(next_version(None, Bump::Patch), (0, 0, 1));
        assert_eq!(next_version(None, Bump::Major), (0, 0, 1));
    }

    #[test]
    fn bump_levels_step_correctly() {
        let cur = Some((1, 8, 0));
        assert_eq!(next_version(cur, Bump::Patch), (1, 8, 1));
        assert_eq!(next_version(cur, Bump::Minor), (1, 9, 0));
        assert_eq!(next_version(cur, Bump::Major), (2, 0, 0));
        assert_eq!(fmt_version((2, 0, 0)), "v2.0.0");
    }

    #[test]
    fn version_note_is_scoped_as_a_task_list() {
        let t = version_template("v0.0.1");
        assert!(t.contains("id: v0.0.1"));
        assert!(t.contains("- [ ]")); // an open task to scope into
    }

    #[test]
    fn template_carries_the_load_bearing_markers() {
        let t = summary_template("my-app");
        // preflight greps the agents heading; lab-sync greps the AUTO/STATUS markers
        assert!(t.contains("## → For the agents"));
        assert!(t.contains("STATUS:START") && t.contains("STATUS:END"));
        assert!(t.contains("AUTO:START") && t.contains("AUTO:END"));
        assert!(t.contains("<!-- canonical: my-app -->"));
    }
}
