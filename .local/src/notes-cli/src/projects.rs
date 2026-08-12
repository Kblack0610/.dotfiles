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
use crate::waves;
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

/// `notes projects` — print `"<name>\t<summary-path>\t<status>\t<version>"` per indexed
/// project. `<status>` is the agent-written note in the summary's `STATUS:START`/`STATUS:END`
/// block (empty when unwritten); `<version>` is the sheet's `Version:` line, else the highest
/// version note (empty when neither).
pub fn list(p: &Profile) -> Result<()> {
    for (name, summary) in indexed(p) {
        let status = fs::read_to_string(&summary)
            .ok()
            .and_then(|c| status_line(&c))
            .unwrap_or_default();
        let version = summary.parent().map(version_str).unwrap_or_default();
        println!("{}\t{}\t{}\t{}", name, summary.display(), status, version);
    }
    Ok(())
}

/// The project's OPEN version as a display string (`"v0.0.1"`), or "" when it has none.
/// `dir` is the project directory (the summary's parent).
///
/// Open, not shipped — the cockpit puts this beside the project name, and what belongs
/// there is the batch in flight. A sheet-model project has always shown that (its
/// `Version:` line names the open version while `versions/` holds the frozen ones); a
/// legacy changelog-only project used to show its last RELEASE in the same slot, so one
/// column meant two different things depending on which model a project happened to be on.
fn version_str(dir: &Path) -> String {
    open_version(dir).map(fmt_version).unwrap_or_default()
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

/// `- [[<vault-relative target>|<name>]]` — the index lane entry for a project note.
fn lane_line(p: &Profile, target: &Path, name: &str) -> String {
    format!("- [[{}|{}]]", config::wikilink(&p.root, target), name)
}

/// The index-lane link target for a project dir: its working sheet if it has one, else
/// `summary.md` — so the hub `## Current` lane (and thus the daily note) point at the
/// editable sheet, not the machine cockpit.
fn lane_target(dir: &Path) -> PathBuf {
    sheet_path(dir).unwrap_or_else(|| dir.join("summary.md"))
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

/// Scaffold for a new `summary.md` — the machine COCKPIT. The task list lives on the
/// README sheet ([`sheet_body`]); this file only carries what the tools grep. The
/// cockpit/STATUS/AUTO markers are load-bearing (lab-sync keys on them), so they are
/// verbatim.
///
/// There is deliberately NO `## → For the agents` section. It was the human's channel TO
/// the agent, and it was the wrong one in the most complete way available: the session
/// preflight read it, and it sat as the untouched placeholder in all seven live projects,
/// while the project BOARD held 41 open items — 21 of them `#ai` — that nothing read.
/// Scaffolding it into every new project only widened the trap, because a section that
/// invites you to "type a want" and is then read by nothing is worse than no section.
/// The `#ai` lane on the board is the channel now, and the preflight reads that.
///
/// There is deliberately NO `<!-- canonical: -->` line. The directory name IS the
/// project name: project-map.json is the sole registry and the sole minter, and
/// project-map-doctor fails if a lab directory has no entry there. Scaffolding a marker
/// here is what created the problem it was meant to solve -- every new project got a
/// second, hand-editable place to declare its name, and four of them ended up naming
/// projects the registry had never heard of.
fn summary_template(name: &str) -> String {
    format!(
        "---\nid: summary\naliases: []\ntags: []\n---\n\n# {name}\n\
<!-- cockpit: vikunja= release-epic= pathfilter= branch= prfilter= -->\n\n\
Working sheet: [[README]] - this file is the machine cockpit (lab-sync / preflight read it). Edit README, not here.\n\n\
Wants for the agents go on the BOARD, not here: `notes ptask {name} add \"<title>\" #ai` (the session preflight injects that lane at turn 1).\n\n\
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
    // the working sheet (README.md) holds the task list; every project starts at v0.0.1.
    fs::write(
        dir.join("README.md"),
        sheet_body(&format!("# {name}"), "v0.0.1"),
    )?;

    if let Some(idx) = &p.project_index {
        let content = fs::read_to_string(idx).unwrap_or_default();
        let content = strip_lane_placeholder(&content, "Current");
        let target = lane_target(&dir);
        let content = md::insert_under_heading(&content, "Current", &[lane_line(p, &target, name)]);
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
    move_lane(p, "Current", "Archived", name, &lane_target(&dest))?;
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
    move_lane(p, "Archived", "Current", name, &lane_target(&dest))?;
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

/// The `Version: vX.Y.Z` declared on a working sheet (first such line), parsed. `None`
/// when the sheet has no version line.
fn sheet_version(content: &str) -> Option<(u32, u32, u32)> {
    content
        .lines()
        .find_map(|l| parse_version(l.trim().strip_prefix("Version:")?.trim()))
}

/// A project's working SHEET — the human-edited task list (title + `Version: vX.Y.Z` +
/// waves). `README.md` is the sheet when it carries a `Version:` line; otherwise (a prose
/// brief, e.g. media_player_fleet) `tasks.md` is. `None` for a summary-cockpit-only /
/// legacy version-note project, which has no sheet to edit or roll.
pub(crate) fn sheet_path(dir: &Path) -> Option<PathBuf> {
    let readme = dir.join("README.md");
    if fs::read_to_string(&readme)
        .ok()
        .as_deref()
        .is_some_and(|c| sheet_version(c).is_some())
    {
        return Some(readme);
    }
    let tasks = dir.join("tasks.md");
    tasks.exists().then_some(tasks)
}

/// A project's current version: the sheet's `Version:` line is the source of truth;
/// legacy projects with no sheet fall back to the highest `vX.Y.Z.md` note (root +
/// `changelog/`).
fn current_version(dir: &Path) -> Option<(u32, u32, u32)> {
    if let Some(sheet) = sheet_path(dir) {
        if let Some(v) = fs::read_to_string(&sheet).ok().and_then(|c| sheet_version(&c)) {
            return Some(v);
        }
    }
    let mut best = None;
    scan_versions(dir, &mut best);
    scan_versions(&dir.join("changelog"), &mut best);
    best
}

/// The version currently OPEN — the one being worked on, which is what a wave ships as.
/// Distinct from `current_version`, which is the highest version RECORDED.
///
/// For a sheet-model project those coincide: the `Version:` line names the open version,
/// and `roll` freezes the sheet under that name before advancing it. For a legacy project
/// that records releases as `changelog/vX.Y.Z.md` notes and carries no `Version:` line they
/// do NOT: the highest note is the last version SHIPPED, so the open one is the next patch.
///
/// Conflating them is not cosmetic. A wave takes its entire identity from this number —
/// branch, PR, blackboard, and the note it freezes on merge. Reading back a shipped version
/// means a wave names itself after a release that is already tagged and in the CHANGELOG,
/// then freezes a second, different note under that same name.
fn open_version(dir: &Path) -> Option<(u32, u32, u32)> {
    if let Some(sheet) = sheet_path(dir) {
        if let Some(v) = fs::read_to_string(&sheet).ok().and_then(|c| sheet_version(&c)) {
            return Some(v);
        }
    }
    // No `Version:` line: everything findable has already gone out, so open the next patch.
    Some(next_version(current_version(dir), Bump::Patch))
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
pub(crate) fn project_dir(p: &Profile, name: &str) -> Result<PathBuf> {
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
///
/// Legacy verb for the version-note projects (each `vX.Y.Z.md` is its own task list). New
/// sheet-model projects use `--roll` instead, which freezes the whole sheet on rollover.
pub fn bump(p: &Profile, log: &Logger, name: &str, level: Bump) -> Result<()> {
    let dir = project_dir(p, name)?;
    let ver = fmt_version(next_version(current_version(&dir), level));
    let path = write_version_note(&dir, &ver)?;
    log.info("projects", &format!("{name} -> {ver}"));
    println!("{}", path.display());
    Ok(())
}

/// The reset body of a freshly-rolled (or newly-created) sheet: title, the version line,
/// and an empty current wave, NAMED for the version it will ship as.
///
/// A wave IS the patch version: a batch of fixes ships as `x.x.+1`, a release is `x.+1.x`,
/// a breaking change `+1.x.x`. Seeding the heading with the literal string `new` broke
/// that at the only point it could have been established — the wave had no id of its own,
/// so its branch, its blackboard and the note it freezes into all reached for a date
/// instead, and a frozen `versions/vX.Y.Z.md` could not say which wave it had been. The
/// version is already on the line above; this makes the wave carry it too, so one id runs
/// from the sheet through the branch and PR to the frozen note.
fn sheet_body(title: &str, ver: &str) -> String {
    format!(
        "{title}\nVersion: {ver}\n\n## {}\n- [ ] \n",
        waves::heading_current(ver)
    )
}

/// The version a sheet's wave should be NAMED for: the sheet's own `Version:` line, else
/// `v0.0.1` for a sheet that has none yet. Keeps `Version:` the single source of truth —
/// a wave is never named anything the sheet has not already declared.
pub(crate) fn wave_version_of(content: &str) -> String {
    sheet_version(content).map_or_else(|| "v0.0.1".to_string(), fmt_version)
}

/// Does this sheet already carry a `## Wave` section? (The task-sheet test.)
fn has_wave(content: &str) -> bool {
    !waves::sections(content).is_empty()
}

/// The sheet to roll, ADOPTING a wave sheet that never got a `Version:` line.
///
/// `sheet_path` accepts `README.md` only when it declares a version, so a project whose
/// sheet grew organically — a `## Wave` the human has been adding tasks to, with no
/// version line above it — fell through to the legacy branch of `roll`, which writes a
/// changelog note and leaves the wave in place. That is the worst possible outcome: the
/// roll reports success, freezes nothing, and the task list silently keeps growing.
///
/// So adopt it. The version is not invented: `current_version` finds the highest version
/// the project has already recorded in its `changelog/`, and the sheet opens at the NEXT
/// PATCH after it. The distinction matters — a sheet's `Version:` line names the version
/// currently OPEN, not the last one shipped (`roll` freezes the sheet UNDER that name and
/// then advances it), so seeding at the changelog's max would re-open a version that has
/// already gone out. Nothing is adopted that is not already being used as a wave sheet.
fn sheet_to_roll(dir: &Path, log: &Logger) -> Result<Option<PathBuf>> {
    if let Some(s) = sheet_path(dir) {
        return Ok(Some(s));
    }
    let readme = dir.join("README.md");
    let Ok(content) = fs::read_to_string(&readme) else {
        return Ok(None);
    };
    if !has_wave(&content) || sheet_version(&content).is_some() {
        return Ok(None);
    }
    // The SAME number `--version-of` reports, so what the wave read at scope-out is what
    // lands on the sheet when it rolls. Deriving it twice is how the two drift apart.
    let ver = fmt_version(open_version(dir).unwrap_or((0, 0, 1)));
    // Under the title line, so the sheet matches what `sheet_body` writes.
    let mut lines: Vec<String> = content.lines().map(str::to_string).collect();
    let at = usize::from(!lines.is_empty());
    lines.insert(at, format!("Version: {ver}"));
    md::write_atomic(&readme, &format!("{}\n", lines.join("\n")))?;
    let msg = format!("adopted {} at {ver}", readme.display());
    log.info("projects", &msg);
    println!("adopted {} onto the sheet model at {ver}", readme.display());
    Ok(Some(readme))
}

/// Why this version cannot close, if it cannot: the current wave still has open tasks.
///
/// `None` means the gate is satisfied. Separate from `roll` so the rule is testable
/// without a profile or a vault — this is the check that decides whether "rolled" means
/// "finished", and a check nothing can exercise is a check that quietly stops holding.
fn roll_blocker(
    content: &str,
    name: &str,
    cur: (u32, u32, u32),
    next: (u32, u32, u32),
) -> Option<String> {
    let current = waves::sections(content).into_iter().next()?;
    let open = waves::open_tasks(content, &current);
    if open.is_empty() {
        return None;
    }
    let listed = open
        .iter()
        .map(|l| format!("  {}", l.trim()))
        .collect::<Vec<_>>()
        .join("\n");
    Some(format!(
        "{} has {} open task(s) - a version does not close until its work is done:\n{listed}\n\n\
         finish them, or move them forward:\n  \
         notes ptask {name} move \"<word from the task>\" --to {}\n\
         override with --force",
        fmt_version(cur),
        open.len(),
        fmt_version(next)
    ))
}

/// Rebuild a sheet for the next version: freeze the CURRENT wave, promote the planned
/// wave named `next` if there is one, and carry the rest of the roadmap over untouched.
/// Returns `(frozen_note_body, new_sheet_body)`.
///
/// Split out of `roll` so it is testable without a profile, a vault or a filesystem —
/// this is the part that can silently eat work, and it is the part that needs the
/// negative controls.
fn rebuild_sheet(content: &str, cur: (u32, u32, u32), next: (u32, u32, u32)) -> (String, String) {
    let cur_s = fmt_version(cur);
    let next_s = fmt_version(next);
    let title = content.lines().next().unwrap_or("# project").to_string();

    let secs = waves::sections(content);
    let Some(current) = secs.first().cloned() else {
        // No wave at all (a bare sheet): nothing to freeze but the file itself, and
        // nothing to promote. Behaves exactly as it did before the roadmap existed.
        return (content.to_string(), sheet_body(&title, &next_s));
    };

    // FREEZE: the title, the version line as it stood, and the current wave alone. The
    // planned waves are the future and have no business in a release record.
    let head = format!("{title}\nVersion: {cur_s}\n");
    let body: String = content
        .lines()
        .skip(current.start)
        .take(current.end - current.start)
        .collect::<Vec<_>>()
        .join("\n");
    let frozen = format!("{head}\n{}\n", body.trim_end());

    // PROMOTE: the sheet keeps everything below the current wave. If the roadmap already
    // holds a wave named `next`, it becomes the current one, tasks and all — that is the
    // whole point of planning forward. Otherwise open an empty one.
    let (rest, _) = waves::cut(content, &current);
    let rest_secs = waves::sections(&rest);
    let promoted = rest_secs.iter().find(|s| s.version == Some(next)).cloned();

    let mut out: Vec<String> = vec![title, format!("Version: {next_s}"), String::new()];
    match promoted {
        Some(s) => {
            // Re-title it `(current)` and lift it to the top; everything else keeps its order.
            let (without, mut taken) = waves::cut(&rest, &s);
            taken[0] = format!("## {}", waves::heading_current(&next_s));
            out.extend(taken.into_iter().map(|l| l.trim_end().to_string()));
            out.push(String::new());
            out.extend(body_after_head(&without));
        }
        None => {
            out.push(format!("## {}", waves::heading_current(&next_s)));
            out.push("- [ ] ".to_string());
            out.push(String::new());
            out.extend(body_after_head(&rest));
        }
    }
    // Collapse runs of blank lines the cut/paste can leave behind.
    let mut sheet: Vec<String> = Vec::new();
    for l in out {
        if l.trim().is_empty() && sheet.last().is_some_and(|p: &String| p.trim().is_empty()) {
            continue;
        }
        sheet.push(l);
    }
    while sheet.last().is_some_and(|l| l.trim().is_empty()) {
        sheet.pop();
    }
    (frozen, format!("{}\n", sheet.join("\n")))
}

/// A sheet's content with its title line and `Version:` line dropped — the part that gets
/// re-attached under a freshly written head.
fn body_after_head(content: &str) -> Vec<String> {
    content
        .lines()
        .skip(1) // the title
        .filter(|l| !l.trim_start().starts_with("Version:"))
        .map(|l| l.trim_end().to_string())
        .skip_while(|l| l.trim().is_empty())
        .collect()
}

/// `notes projects --roll <name> [--minor|--major] [--force]` — close the current version
/// and open the next on the working sheet.
///
/// Three steps, and the first one is why this is not a one-liner:
///
/// 1. **Gate.** A version with open tasks does not roll. Rolling used to mean "we moved
///    on": it froze the whole sheet and reset it to an empty wave, so anything still
///    unchecked left the live sheet and survived only inside the frozen note. That is how
///    `versions/v1.12.0.md` ended up holding six open items — a full-flow e2e, the
///    database recovery runbook, an account reset — that are on no live list anywhere.
///    A closed version now means the work is FINISHED, or a human explicitly moved it on
///    with `notes ptask <name> move "<q>" --to <ver>`. `--force` is the deliberate override.
/// 2. **Freeze.** Only the current wave goes into `versions/<vX.Y.Z>.md` (never
///    overwriting a frozen one), stamped with the epoch that bounds this version's work.
/// 3. **Promote.** A planned `## Wave: <next>` becomes the current wave, carrying its
///    tasks; the rest of the roadmap carries over untouched.
pub fn roll(p: &Profile, log: &Logger, name: &str, level: Bump, force: bool) -> Result<()> {
    let dir = project_dir(p, name)?;
    let Some(sheet) = sheet_to_roll(&dir, log)? else {
        // No sheet (a legacy / changelog-only project): advance by writing the next version
        // note, so the cockpit's roll shortcut still does something sensible everywhere.
        let ver = fmt_version(next_version(current_version(&dir), level));
        let path = write_version_note(&dir, &ver)?;
        log.info("projects", &format!("{name} -> {ver} (version note)"));
        println!("rolled {name}: -> {ver} ({})", path.display());
        return Ok(());
    };
    let content = fs::read_to_string(&sheet)?;
    let cur = sheet_version(&content)
        .ok_or_else(|| anyhow::anyhow!("no `Version: vX.Y.Z` line on {}", sheet.display()))?;
    let next = next_version(Some(cur), level);

    // 1. the gate
    if !force {
        if let Some(why) = roll_blocker(&content, name, cur, next) {
            bail!(why);
        }
    }

    // 2. the freeze
    let versions = dir.join("versions");
    fs::create_dir_all(&versions)?;
    let frozen = versions.join(format!("{}.md", fmt_version(cur)));
    if frozen.exists() {
        bail!(
            "{} already exists — refusing to overwrite a frozen version",
            frozen.display()
        );
    }
    let (frozen_body, new_sheet) = rebuild_sheet(&content, cur, next);
    // Stamp WHEN this version was frozen. That epoch is the boundary between one
    // version's work and the next, and consumers (the cockpit's agents panel, the
    // release agent-changelog) need it to scope "what happened this version".
    //
    // It has to be written here rather than inferred from the file's mtime: regenerating
    // an old frozen note's summary (`C-s` in the version browser) rewrites the file and
    // would silently drag the boundary forward by however long ago the release was.
    let stamped = format!(
        "{frozen_body}\n<!-- rolled: {} -->\n",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    fs::write(&frozen, &stamped)?;

    // 3. the promote
    md::write_atomic(&sheet, &new_sheet)?;

    let next_s = fmt_version(next);
    let carried = waves::find(&content, next).is_some();
    log.info(
        "projects",
        &format!("{name} {} -> {next_s} (froze {})", fmt_version(cur), frozen.display()),
    );
    println!(
        "rolled {name}: {} -> {next_s} (froze {})",
        fmt_version(cur),
        frozen.display()
    );
    if carried {
        println!("promoted the planned wave {next_s} to current");
    }
    Ok(())
}

/// Root `vX.Y.Z.md` version notes (NOT `changelog/` — those are release history), sorted
/// ascending. Each is `(version, path)`.
fn root_version_notes(dir: &Path) -> Vec<((u32, u32, u32), PathBuf)> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for e in entries.flatten() {
            let path = e.path();
            if path.extension().and_then(|x| x.to_str()) != Some("md") {
                continue;
            }
            if let Some(v) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(parse_version)
            {
                out.push((v, path));
            }
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// The task body of a version note: drop its `---` frontmatter block and a leading `# …`
/// title line, keep the rest (the `## Wave …` content), trimmed.
fn note_body(content: &str) -> String {
    let mut lines: Vec<&str> = content.lines().collect();
    // strip a leading frontmatter block (--- … ---)
    if lines.first().map(|l| l.trim()) == Some("---") {
        if let Some(end) = lines.iter().skip(1).position(|l| l.trim() == "---") {
            lines.drain(0..=end + 1);
        }
    }
    // drop leading blanks, then a single leading `# …` H1 title
    while lines.first().map(|l| l.trim().is_empty()).unwrap_or(false) {
        lines.remove(0);
    }
    if lines.first().map(|l| l.starts_with("# ")).unwrap_or(false) {
        lines.remove(0);
    }
    lines.join("\n").trim().to_string()
}

/// Ensure `summary.md` carries the `Working sheet: [[README]]` pointer (idempotent). Inserts
/// it just before the first `## ` heading when absent, and appends when the file has none.
///
/// The template no longer scaffolds a heading above the STATUS marker (the retired
/// `## → For the agents`), so a freshly scaffolded summary takes the append path. Both
/// paths are exercised below; an EXISTING summary still has headings and takes the first.
fn ensure_sheet_pointer(summary: &Path) -> Result<()> {
    let content = fs::read_to_string(summary).unwrap_or_default();
    if content.contains("Working sheet:") {
        return Ok(());
    }
    let pointer = "Working sheet: [[README]] - this file is the machine cockpit (lab-sync / preflight read it). Edit README, not here.";
    let mut out: Vec<String> = Vec::new();
    let mut inserted = false;
    for line in content.lines() {
        if !inserted && line.starts_with("## ") {
            out.push(pointer.to_string());
            out.push(String::new());
            inserted = true;
        }
        out.push(line.to_string());
    }
    if !inserted {
        out.push(String::new());
        out.push(pointer.to_string());
    }
    let mut joined = out.join("\n");
    if !joined.ends_with('\n') {
        joined.push('\n');
    }
    fs::write(summary, joined)?;
    Ok(())
}

/// `notes projects --migrate <name>` — upgrade a legacy root-version-note project to the
/// sheet model (idempotent): the highest `vX.Y.Z.md` becomes the `README.md` sheet (its
/// tasks + a `Version:` line), lower notes move to `versions/`, `summary.md` gains the
/// `[[README]]` pointer, and the hub `## Current` lane repoints at the sheet. Projects with
/// a sheet already, or only `changelog/` notes (release-managed), are left untouched.
pub fn migrate(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let dir = project_dir(p, name)?;
    if sheet_path(&dir).is_some() {
        println!("{name}: already sheet-model — nothing to migrate");
        return Ok(());
    }
    let notes = root_version_notes(&dir);
    let Some(((cur, cur_path), older)) = notes.split_last().map(|(l, r)| (l.clone(), r)) else {
        println!("{name}: no root version note to migrate (changelog-only / release-managed) — skipped");
        return Ok(());
    };

    // highest note -> README sheet (Version line + its task body), then drop the note
    let body = note_body(&fs::read_to_string(&cur_path)?);
    let readme = dir.join("README.md");
    let title = format!("# {name}");
    let sheet = if body.is_empty() {
        sheet_body(&title, &fmt_version(cur))
    } else {
        format!("{title}\nVersion: {}\n\n{body}\n", fmt_version(cur))
    };
    fs::write(&readme, sheet)?;
    fs::remove_file(&cur_path)?;

    // older notes -> versions/
    if !older.is_empty() {
        let versions = dir.join("versions");
        fs::create_dir_all(&versions)?;
        for (v, path) in older {
            let dest = versions.join(format!("{}.md", fmt_version(*v)));
            if !dest.exists() {
                fs::rename(path, &dest)?;
            }
        }
    }

    // summary pointer + repoint the hub lane at the sheet
    ensure_sheet_pointer(&dir.join("summary.md"))?;
    if let Some(idx) = &p.project_index {
        let content = fs::read_to_string(idx).unwrap_or_default();
        if let Some(removed) = remove_from_lane(&content, "Current", name) {
            let with = md::insert_under_heading(&removed, "Current", &[lane_line(p, &readme, name)]);
            fs::write(idx, with)?;
        }
    }

    log.info("projects", &format!("migrated {name} to sheet model at {}", fmt_version(cur)));
    println!("migrated {name}: {} -> README.md sheet (versions/ for older)", fmt_version(cur));
    Ok(())
}

/// `notes projects --version-of <name>` — print the version currently OPEN: what the
/// project is working towards, and what a wave started now will ship as. NOT the last
/// version shipped.
pub fn show_version(p: &Profile, name: &str) -> Result<()> {
    let dir = project_dir(p, name)?;
    if let Some(v) = open_version(&dir) {
        println!("{}", fmt_version(v));
    }
    Ok(())
}

/// `notes projects --waves <name>` — the project's ROADMAP, current wave first, as TSV:
/// `version<TAB>state<TAB>open<TAB>done<TAB>heading`.
///
/// TSV rather than prose because the cockpit's version browser reads it to build its rows;
/// `state` is `current` or `planned`.
pub fn show_waves(p: &Profile, name: &str) -> Result<()> {
    let dir = project_dir(p, name)?;
    let Some(sheet) = sheet_path(&dir) else {
        return Ok(());
    };
    let content = fs::read_to_string(&sheet)?;
    for (i, s) in waves::sections(&content).iter().enumerate() {
        let open = waves::open_tasks(&content, s).len();
        let done = content
            .lines()
            .skip(s.start + 1)
            .take(s.end.saturating_sub(s.start + 1))
            .filter(|l| md::is_checked(l))
            .count();
        let state = if i == 0 { "current" } else { "planned" };
        println!("{}\t{state}\t{open}\t{done}\t{}", s.label(), s.heading);
    }
    Ok(())
}

/// A project's AI note for `ver`: `<project>/ai/<vX.Y.Z>.md`.
///
/// ONE resolver, so no writer guesses the path. The agents' evidence for a version used to
/// live only on the runtime axis (`~/.agent/plans/<app>/wave-<ver>-report.md`), where the
/// human never sees it and where it is eventually archived; this puts it in the lab dir
/// beside the frozen version note it belongs to. Version-named, so a roll moves nothing.
pub(crate) fn ai_note_path(dir: &Path, ver: &str) -> PathBuf {
    dir.join("ai").join(format!("{ver}.md"))
}

/// The AI note for `ver`, created (with its `## Proof` table and `## Notes` log) if absent.
pub(crate) fn ensure_ai_note(dir: &Path, project: &str, ver: &str) -> Result<PathBuf> {
    let path = ai_note_path(dir, ver);
    if path.exists() {
        return Ok(path);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(
        &path,
        format!(
            "# {project} {ver} - AI notes\n\n\
             What the agents did for this version and the evidence behind it. The human's \
             task list is the sheet (`README.md`); this is the proof and the working log \
             underneath it. Rows are appended by `notes ptask <project> done`.\n\n\
             ## Proof\n\
             | task | proof | when |\n\
             |---|---|---|\n\n\
             ## Notes\n"
        ),
    )?;
    Ok(path)
}

/// Append a row to an AI note's `## Proof` table.
///
/// Inserted after the LAST existing row rather than under the heading, so the table reads
/// oldest-first and a new row can never land between the header and its `|---|` separator
/// (which is what `md::insert_under_heading` would do — it inserts at the top of a section).
pub(crate) fn append_proof(
    dir: &Path,
    project: &str,
    ver: &str,
    task: &str,
    proof: &str,
    when: &str,
) -> Result<PathBuf> {
    let path = ensure_ai_note(dir, project, ver)?;
    let content = fs::read_to_string(&path)?;
    let lines: Vec<&str> = content.lines().collect();
    let row = format!("| {} | {} | {when} |", cell(task), cell(proof));

    let Some(span) = md::section_span(&lines, "Proof") else {
        // No `## Proof` section (a hand-edited note): append one rather than lose the row.
        let mut out = content.trim_end().to_string();
        out.push_str(&format!("\n\n## Proof\n| task | proof | when |\n|---|---|---|\n{row}\n"));
        md::write_atomic(&path, &out)?;
        return Ok(path);
    };
    let at = lines[span.clone()]
        .iter()
        .rposition(|l| l.trim_start().starts_with('|'))
        .map_or(span.end, |i| span.start + i + 1);
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    out.insert(at, row);
    md::write_atomic(&path, &format!("{}\n", out.join("\n")))?;
    Ok(path)
}

/// Make a string safe inside a markdown table cell.
fn cell(s: &str) -> String {
    s.replace('|', "\\|").trim().to_string()
}

/// `notes projects --ai-note <name> [--version vX.Y.Z]` — print the path to a version's AI
/// note, creating it if absent. The seam every other writer (the wave, the cockpit's roll)
/// goes through instead of building the path themselves.
pub fn show_ai_note(p: &Profile, name: &str, version: Option<&str>) -> Result<()> {
    let dir = project_dir(p, name)?;
    let ver = match version {
        Some(v) => {
            let parsed = waves::parse(v.trim())
                .ok_or_else(|| anyhow::anyhow!("not a version: '{v}' (want vX.Y.Z)"))?;
            waves::fmt(parsed)
        }
        None => fmt_version(open_version(&dir).unwrap_or((0, 0, 1))),
    };
    let path = ensure_ai_note(&dir, name, &ver)?;
    println!("{}", path.display());
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
        let version = summary.parent().map(version_str).unwrap_or_default();
        println!("{}\t{}\t{}\t{}", name, summary.display(), status, version);
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
mod roll_tests {
    use super::*;

    // A sheet mid-roadmap: one open task in the current wave, two versions planned, and a
    // non-wave section that must survive everything.
    const SHEET: &str = "\
# demo
Version: v1.13.0

## Wave: v1.13.0 (current)
- [x] shipped thing <!-- pr:1142 -->
- [ ] still open

## Wave: v1.14.0 (planned)
- [ ] planned thing #ai

## Wave: v1.15.0 (planned)
- [ ] much later

## Backlog
- [ ] someday
";

    fn finished() -> String {
        SHEET.replace("- [ ] still open\n", "")
    }

    // THE gate. Rolling used to freeze a whole sheet and reset it to an empty wave, so an
    // unchecked task left the live sheet and survived only inside the frozen note - which
    // is how six open items ended up sealed inside versions/v1.12.0.md and on no live list
    // anywhere. If this test ever passes with `is_none()`, that behaviour is back.
    #[test]
    fn a_version_with_open_work_refuses_to_close() {
        let why = roll_blocker(SHEET, "demo", (1, 13, 0), (1, 14, 0));
        let why = why.expect("an open task must block the roll");
        assert!(why.contains("still open"), "it must name what is blocking: {why}");
        assert!(why.contains("move"), "and how to move it on: {why}");
    }

    // The positive half: an empty wave rolls, and a CHECKED task is not "open".
    #[test]
    fn a_finished_version_closes() {
        assert!(roll_blocker(&finished(), "demo", (1, 13, 0), (1, 14, 0)).is_none());
    }

    // Only the planned waves stop it - work planned for LATER is not work owed now.
    #[test]
    fn a_planned_wave_full_of_open_tasks_does_not_block_the_roll() {
        let s = finished();
        assert!(s.contains("- [ ] planned thing #ai"), "fixture sanity");
        assert!(roll_blocker(&s, "demo", (1, 13, 0), (1, 14, 0)).is_none());
    }

    #[test]
    fn the_freeze_takes_the_current_wave_and_nothing_below_it() {
        let (frozen, _) = rebuild_sheet(&finished(), (1, 13, 0), (1, 14, 0));
        assert!(frozen.contains("Version: v1.13.0"));
        assert!(frozen.contains("shipped thing"));
        // the release record is this version, not the roadmap after it
        assert!(!frozen.contains("v1.14.0"), "planned work is not a release record:\n{frozen}");
        assert!(!frozen.contains("much later"), "{frozen}");
        assert!(!frozen.contains("someday"), "{frozen}");
    }

    // The point of planning forward: the wave you scoped is the wave you get.
    #[test]
    fn the_planned_next_version_is_promoted_with_its_tasks() {
        let (_, sheet) = rebuild_sheet(&finished(), (1, 13, 0), (1, 14, 0));
        assert!(sheet.contains("Version: v1.14.0"), "{sheet}");
        assert!(
            sheet.contains("## Wave: v1.14.0 (current)"),
            "the planned wave becomes the current one:\n{sheet}"
        );
        assert!(sheet.contains("- [ ] planned thing #ai"), "carrying its tasks:\n{sheet}");
        assert!(!sheet.contains("(planned)\n- [ ] planned thing"), "{sheet}");
    }

    // The rest of the roadmap is not collateral damage.
    #[test]
    fn the_rest_of_the_roadmap_and_the_backlog_survive_a_roll() {
        let (_, sheet) = rebuild_sheet(&finished(), (1, 13, 0), (1, 14, 0));
        assert!(sheet.contains("## Wave: v1.15.0 (planned)"), "{sheet}");
        assert!(sheet.contains("- [ ] much later"), "{sheet}");
        assert!(sheet.contains("## Backlog"), "{sheet}");
        assert!(sheet.contains("- [ ] someday"), "{sheet}");
        let secs = waves::sections(&sheet);
        assert_eq!(secs.len(), 2, "current + one planned:\n{sheet}");
        assert_eq!(secs[0].version, Some((1, 14, 0)), "current wave first:\n{sheet}");
    }

    // Rolling to a version nobody planned still opens an empty wave, as it always did.
    #[test]
    fn an_unplanned_next_version_opens_empty() {
        let (_, sheet) = rebuild_sheet(&finished(), (1, 13, 0), (1, 20, 0));
        assert!(sheet.contains("## Wave: v1.20.0 (current)"), "{sheet}");
        let secs = waves::sections(&sheet);
        assert_eq!(secs[0].version, Some((1, 20, 0)));
        // v1.14.0 and v1.15.0 are still planned, untouched
        assert_eq!(secs.len(), 3, "{sheet}");
        assert!(sheet.contains("- [ ] planned thing #ai"), "{sheet}");
    }

    // A sheet from before the roadmap existed: one wave, no planned sections, nothing else.
    #[test]
    fn a_plain_single_wave_sheet_rolls_the_way_it_always_did() {
        let plain = "# d\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [x] a\n";
        let (frozen, sheet) = rebuild_sheet(plain, (0, 1, 0), (0, 1, 1));
        assert!(frozen.contains("- [x] a"));
        assert!(sheet.contains("Version: v0.1.1"), "{sheet}");
        assert!(sheet.contains("## Wave: v0.1.1 (current)"), "{sheet}");
        assert!(!sheet.contains("- [x] a"), "the closed work does not come back:\n{sheet}");
    }

    #[test]
    fn proof_rows_append_in_order_under_the_table_header() {
        let dir = std::env::temp_dir().join(format!("proj-proof-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        append_proof(&dir, "demo", "v1.13.0", "first task", "pr:1", "2026-08-11").unwrap();
        let path =
            append_proof(&dir, "demo", "v1.13.0", "second | task", "pr:2", "2026-08-11").unwrap();
        let body = fs::read_to_string(&path).unwrap();

        // `|---|` is the separator and does not match `"| "`, so: header + two rows.
        let rows: Vec<&str> = body.lines().filter(|l| l.starts_with("| ")).collect();
        assert_eq!(rows.len(), 3, "header + two rows:\n{body}");
        assert!(rows[1].contains("first task"), "oldest first:\n{body}");
        assert!(rows[2].contains("second \\| task"), "pipes escaped:\n{body}");
        assert!(body.contains("## Notes"), "the log section survives:\n{body}");
        assert_eq!(path, ai_note_path(&dir, "v1.13.0"));
        let _ = fs::remove_dir_all(&dir);
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
        // lab-sync greps the AUTO/STATUS markers
        assert!(t.contains("STATUS:START") && t.contains("STATUS:END"));
        assert!(t.contains("AUTO:START") && t.contains("AUTO:END"));
        // and NOT a canonical marker: the directory name is the project name, so a
        // scaffolded marker is a second source of truth for it from the very first day.
        assert!(!t.contains("canonical:"));
        // the cockpit points at the working sheet; the task list is NOT in summary.md
        assert!(t.contains("Working sheet: [[README]]"));
        // and NOT the retired human->agent channel. It was read by the preflight and
        // written by nobody, in all seven live projects, while the board's `#ai` lane was
        // written by the human and read by nobody. Scaffolding it into every NEW project
        // widened the trap: a section that says "type a want" and is read by nothing is
        // worse than no section. Points at the board instead.
        assert!(!t.contains("For the agents"));
        assert!(t.contains("#ai"));
    }

    #[test]
    fn sheet_version_reads_the_version_line() {
        let sheet = "# My App\nVersion: v0.2.0\n\n## Wave: new\n- [ ] a\n";
        assert_eq!(sheet_version(sheet), Some((0, 2, 0)));
        // a prose brief (no Version: line) is not a sheet
        assert_eq!(sheet_version("# My App\n\nsome docs\n"), None);
        // a non-semver version line does not parse (the roll math needs vX.Y.Z)
        assert_eq!(sheet_version("Version: v1\n"), None);
    }

    #[test]
    fn sheet_body_seeds_a_versioned_wave_list() {
        let b = sheet_body("# My App", "v0.0.1");
        assert!(b.starts_with("# My App\nVersion: v0.0.1"));
        assert!(b.contains("- [ ]"));
        // round-trips: the version we seed is the version the sheet reports
        assert_eq!(sheet_version(&b), Some((0, 0, 1)));
    }

    #[test]
    fn the_wave_is_named_for_the_version_it_ships_as() {
        // A wave IS the patch version. Seeding the heading with the literal `new` left the
        // batch with no id of its own, so its branch, blackboard and frozen note all fell
        // back to a date and nothing could say which wave a `versions/vX.Y.Z.md` had been.
        let b = sheet_body("# My App", "v1.10.1");
        assert!(b.contains("## Wave: v1.10.1 (current)"));
        assert!(!b.contains("## Wave: new"));
    }

    #[test]
    fn a_wave_sheet_with_no_version_line_is_adopted_at_the_next_open_version() {
        // The organically-grown sheet: a `## Wave` the human has been adding to, no `Version:`
        // line, releases recorded in `changelog/`. Before adopting, `roll` fell through to
        // the legacy branch — it reported success, froze nothing, and left the wave in
        // place while the sheet kept growing.
        let tmp = std::env::temp_dir().join(format!("notes-adopt-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("changelog")).unwrap();
        fs::write(tmp.join("changelog/v1.9.0.md"), "").unwrap();
        fs::write(tmp.join("changelog/v1.10.0.md"), "").unwrap();
        let sheet = "# alpha\n\n## Wave: new (current)\n- [ ] a bug\n";
        fs::write(tmp.join("README.md"), sheet).unwrap();

        assert!(sheet_path(&tmp).is_none(), "no Version: line yet");
        let log = Logger::new(tmp.join("log"), false);
        let got = sheet_to_roll(&tmp, &log).unwrap();
        assert_eq!(got, Some(tmp.join("README.md")));

        let after = fs::read_to_string(tmp.join("README.md")).unwrap();
        // The NEXT patch after the highest shipped release, not that release itself: a
        // sheet's `Version:` names the version still open. Seeding at v1.10.0 would
        // re-open a version already sitting in changelog/, and the next roll would freeze
        // a second, different v1.10.0.
        assert_eq!(sheet_version(&after), Some((1, 10, 1)));
        assert!(after.starts_with("# alpha\nVersion: v1.10.1\n"));
        // the human's task survives adoption
        assert!(after.contains("- [ ] a bug"));
        // and it is now a real sheet, so the next roll freezes it
        assert!(sheet_path(&tmp).is_some());
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn adoption_leaves_alone_anything_that_is_not_a_wave_sheet() {
        // NEGATIVE CONTROL. A prose brief with no `## Wave` must keep falling through to
        // the legacy version-note path; adopting it would put a version line on a document
        // that has no task list to freeze.
        let tmp = std::env::temp_dir().join(format!("notes-adopt-neg-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let brief = "# a brief\n\nsome prose, no task list.\n";
        fs::write(tmp.join("README.md"), brief).unwrap();

        let log = Logger::new(tmp.join("log"), false);
        assert_eq!(sheet_to_roll(&tmp, &log).unwrap(), None);
        let after = fs::read_to_string(tmp.join("README.md")).unwrap();
        assert!(!after.contains("Version:"));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn adoption_never_overwrites_a_version_the_sheet_already_declares() {
        let tmp = std::env::temp_dir().join(format!("notes-adopt-keep-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let sheet = "# app\nVersion: v0.4.2\n\n## Wave: v0.4.2\n- [ ] x\n";
        fs::write(tmp.join("README.md"), sheet).unwrap();

        let log = Logger::new(tmp.join("log"), false);
        let readme = tmp.join("README.md");
        assert_eq!(sheet_to_roll(&tmp, &log).unwrap(), Some(readme));
        let after = fs::read_to_string(tmp.join("README.md")).unwrap();
        assert_eq!(sheet_version(&after), Some((0, 4, 2)));
        assert_eq!(after.matches("Version:").count(), 1);
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn open_version_is_the_next_patch_when_every_recorded_version_has_shipped() {
        // The live shape this was found in: releases recorded as `changelog/vX.Y.Z.md`, no
        // `Version:` line, and v1.10.0 already TAGGED and in the app's CHANGELOG. A wave
        // reading that back would name its branch, board and frozen note after a release
        // that has already gone out, then freeze a second, different v1.10.0.
        let tmp = std::env::temp_dir().join(format!("notes-open-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("changelog")).unwrap();
        fs::write(tmp.join("changelog/v1.9.0.md"), "").unwrap();
        fs::write(tmp.join("changelog/v1.10.0.md"), "").unwrap();

        // the highest RECORDED version is still the shipped one - that gap is the point
        assert_eq!(current_version(&tmp), Some((1, 10, 0)));
        // the OPEN one, which is what a wave ships as, is the next patch
        assert_eq!(open_version(&tmp), Some((1, 10, 1)));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn open_version_trusts_a_sheet_that_declares_one() {
        // NEGATIVE CONTROL. A sheet-model project's `Version:` line ALREADY names the open
        // version - `roll` freezes the sheet under it, then advances. Bumping here as well
        // would skip a version on every project not on the legacy model.
        let tmp = std::env::temp_dir().join(format!("notes-open-sheet-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("versions")).unwrap();
        fs::write(tmp.join("versions/v0.0.1.md"), "").unwrap();
        let sheet = "# app\nVersion: v0.0.2\n\n## Wave: v0.0.2 (current)\n- [ ] x\n";
        fs::write(tmp.join("README.md"), sheet).unwrap();

        assert_eq!(open_version(&tmp), Some((0, 0, 2)));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn a_project_with_no_version_at_all_opens_at_the_seed() {
        let tmp = std::env::temp_dir().join(format!("notes-open-new-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        assert_eq!(current_version(&tmp), None);
        assert_eq!(open_version(&tmp), Some((0, 0, 1)));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn adoption_writes_the_same_version_that_version_of_reported() {
        // The wave reads `--version-of` at scope-out; the roll writes the sheet on merge.
        // Derive that number in two places and they can disagree, and the wave freezes
        // under a name no other artifact used.
        let tmp = std::env::temp_dir().join(format!("notes-open-agree-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("changelog")).unwrap();
        fs::write(tmp.join("changelog/v1.10.0.md"), "").unwrap();
        let sheet = "# alpha\n\n## Wave: new (current)\n- [ ] a bug\n";
        fs::write(tmp.join("README.md"), sheet).unwrap();

        let reported = fmt_version(open_version(&tmp).unwrap());
        let log = Logger::new(tmp.join("log"), false);
        sheet_to_roll(&tmp, &log).unwrap();
        let after = fs::read_to_string(tmp.join("README.md")).unwrap();
        assert_eq!(fmt_version(sheet_version(&after).unwrap()), reported);
        assert_eq!(reported, "v1.10.1");
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn has_wave_matches_the_heading_the_task_cli_resolves() {
        assert!(has_wave("# a\n\n## Wave: v1.0.1 (current)\n"));
        assert!(has_wave("# a\n\n## Wave\n"));
        // A PREFIX match, deliberately: `project_tasks::current_wave` resolves the heading
        // the same way, so anything it would treat as the wave section must be adoptable.
        assert!(has_wave("# a\n\n## Waves\n"));
        assert!(!has_wave("# a\n\n### Wave: nested\n")); // H3 is not the wave section
        assert!(!has_wave("# a\n\nno headings here\n"));
    }
}
