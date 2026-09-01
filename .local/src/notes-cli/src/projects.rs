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
use crate::project_tasks;
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

// -- the cockpit marker: declared per-project facts -------------------------
//
// `<!-- cockpit: vikunja=3 stage=prod pathfilter=apps/x -->` in `summary.md` is the one
// place a project declares a fact no tool can derive. Three consumers already grep it
// (regen-project-index.sh's `resolve_canonical`, regen-lab-feed.sh, notes-cockpit.sh's
// `epic_of`), so keys go HERE rather than into a second file.
//
// Every key below is written only through `set_marker_key`, against a closed vocabulary.
// That is the whole lesson of `<!-- canonical: NAME -->` (see `summary_template`): a
// hand-editable declaration drifts from the registry, and four projects ended up naming
// projects nothing had heard of. A field worth trusting is a field one verb owns.

/// The maturity ladder, least to most real. A project's `stage=` must be one of these.
///
/// This is a JUDGEMENT, not a derivation: a toy app and a load-bearing one both ship real
/// git tags at similar version numbers, and only a human knows that breaking one is a
/// shrug and breaking the other is an incident. What IS checkable is the floor: a project
/// claiming the top rung while nothing has ever shipped. `project-map-doctor` checks that
/// against git, and leaves the ranking alone.
pub(crate) const STAGES: [&str; 4] = ["draft", "alpha", "beta", "prod"];

/// The value of `key` in the summary's `<!-- cockpit: ... -->` marker.
///
/// `None` when there is no marker or the key is absent; `Some("")` when the key is
/// present but unset, which is what the scaffold writes and is a different fact from
/// "never declared".
pub(crate) fn marker_key(content: &str, key: &str) -> Option<String> {
    let line = content.lines().find(|l| l.contains("<!-- cockpit:"))?;
    let inner = line.split("<!-- cockpit:").nth(1)?.split("-->").next()?;
    inner
        .split_whitespace()
        .find_map(|tok| tok.strip_prefix(key)?.strip_prefix('=').map(str::to_string))
}

/// Rewrite `key` in the summary's cockpit marker, preserving every other key and their
/// order. An absent key is appended at the end of the marker.
///
/// `Err` when the file carries no cockpit marker at all. That is deliberate: a silent
/// no-op would report success while writing nothing, and the caller would have no way to
/// tell a set-to-empty from a project the scaffold never gave a marker.
fn set_marker_key(content: &str, key: &str, value: &str) -> Result<String> {
    let Some(idx) = content.lines().position(|l| l.contains("<!-- cockpit:")) else {
        bail!("summary has no `<!-- cockpit: … -->` marker to write into");
    };
    let mut lines: Vec<String> = content.lines().map(str::to_string).collect();
    let line = &lines[idx];
    let (head, rest) = line.split_once("<!-- cockpit:").unwrap();
    let (inner, tail) = rest.split_once("-->").unwrap();

    let mut toks: Vec<String> = inner.split_whitespace().map(str::to_string).collect();
    let pair = format!("{key}={value}");
    match toks
        .iter()
        .position(|t| t.split_once('=').map(|(k, _)| k) == Some(key))
    {
        Some(i) => toks[i] = pair,
        None => toks.push(pair),
    }
    lines[idx] = format!("{head}<!-- cockpit: {} -->{tail}", toks.join(" "));

    let mut out = lines.join("\n");
    if content.ends_with('\n') {
        out.push('\n');
    }
    Ok(out)
}

/// Read or write one cockpit-marker key on a project, resolving the name across orgs.
/// `value` of `None` prints the current value (an empty line when unset).
fn marker_verb(p: &Profile, log: &Logger, name: &str, key: &str, value: Option<&str>) -> Result<()> {
    let dir = project_dir(p, name)?;
    let summary = dir.join("summary.md");
    let content = fs::read_to_string(&summary)
        .map_err(|e| anyhow::anyhow!("{}: {e}", summary.display()))?;

    let Some(value) = value else {
        println!("{}", marker_key(&content, key).unwrap_or_default());
        return Ok(());
    };

    let updated = set_marker_key(&content, key, value)?;
    if updated != content {
        fs::write(&summary, &updated)?;
        log.info("projects", &format!("{name}: {key}={value}"));
    }
    println!("{} {key}={value}", summary.display());
    Ok(())
}

/// `notes projects --stage <name> [--set <value>]`: read or declare a project's maturity.
pub fn stage(p: &Profile, log: &Logger, name: &str, value: Option<&str>) -> Result<()> {
    if let Some(v) = value {
        if !STAGES.contains(&v) {
            bail!("unknown stage '{v}' (want: {})", STAGES.join(", "));
        }
    }
    marker_verb(p, log, name, "stage", value)
}

/// `notes projects --group <name> [--set <value>]`: read or declare a project's index
/// group (`bnb`, `personal`, `dev`, ...).
///
/// Validated as a slug rather than against a fixed list, because a new group is a lane on
/// one page, not a code change. The index appends a group it does not know about instead
/// of dropping it, so a typo shows up as its own heading rather than as a missing project.
pub fn group(p: &Profile, log: &Logger, name: &str, value: Option<&str>) -> Result<()> {
    if let Some(v) = value {
        if !v.is_empty() && !v.chars().all(|c| c.is_ascii_lowercase() || c == '-') {
            bail!("group '{v}' must be lowercase letters and hyphens");
        }
    }
    marker_verb(p, log, name, "group", value)
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
///
/// `stage=draft` IS scaffolded, and the distinction from `canonical:` is that one verb
/// owns it (`--stage`, closed vocabulary) and `notes doctor` checks it. A new project is
/// a draft by definition, so the scaffolded value is the true one rather than a prompt to
/// go and type something. `group=` is left empty: unset means "this project's own
/// profile", which is right for all but the handful that want a lane of their own.
fn summary_template(name: &str) -> String {
    format!(
        "---\nid: summary\naliases: []\ntags: []\n---\n\n# {name}\n\
<!-- cockpit: vikunja= release-epic= stage=draft group= pathfilter= branch= prfilter= -->\n\n\
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

pub(crate) fn fmt_version(v: (u32, u32, u32)) -> String {
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
pub(crate) fn sheet_version(content: &str) -> Option<(u32, u32, u32)> {
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

/// A project's current version. The sheet's `Version:` line is the source of truth; a sheet
/// that has lost it falls back to the highest note in `versions/`.
///
/// `versions/` and nothing else. The fallback used to scan the project root and `changelog/`
/// instead - the two places the frozen record is NOT kept - so the one directory holding
/// frozen versions was invisible here while two legacy locations were authoritative.
fn current_version(dir: &Path) -> Option<(u32, u32, u32)> {
    if let Some(sheet) = sheet_path(dir) {
        if let Some(v) = fs::read_to_string(&sheet).ok().and_then(|c| sheet_version(&c)) {
            return Some(v);
        }
    }
    let mut best = None;
    scan_versions(&dir.join("versions"), &mut best);
    best
}

/// The version currently OPEN - the one being worked on, which is what a wave ships as.
/// Distinct from `current_version`, which is the highest version RECORDED.
///
/// Normally they coincide: the `Version:` line names the open version, and `roll` freezes
/// the sheet under that name before advancing it. They diverge only for a sheet with no
/// `Version:` line, where everything in `versions/` has already been frozen, so the open
/// version is the next patch after the highest of them.
///
/// Conflating them is not cosmetic: a wave takes its identity from this number - branch,
/// PR, blackboard, and the note it freezes on merge. Reading back an already-frozen version
/// makes a wave name itself after one, then freeze a second, different note under that name.
pub(crate) fn open_version(dir: &Path) -> Option<(u32, u32, u32)> {
    if let Some(sheet) = sheet_path(dir) {
        if let Some(v) = fs::read_to_string(&sheet).ok().and_then(|c| sheet_version(&c)) {
            return Some(v);
        }
    }
    // No `Version:` line: everything in `versions/` is already frozen, so open the next patch.
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

/// That org's current project by name (case-insensitive), if it has one.
fn project_dir_in(p: &Profile, want: &str) -> Option<PathBuf> {
    indexed(p)
        .into_iter()
        .find(|(n, _)| n.to_lowercase() == want)
        .and_then(|(_, summary)| summary.parent().map(|d| d.to_path_buf()))
}

/// Resolve a current project's directory by name (case-insensitive), ACROSS ORGS.
///
/// A project name used to be resolvable only within the active org, so addressing a project
/// required knowing which org it was in:
///
///   notes ptask <name> list                 -> no current project named '<name>'
///   notes ptask --profile <org> <name> list  -> works
///
/// That does not scale with the number of orgs -- it is a flag whose correct value you memorise
/// per project -- and a keybinding cannot supply it at all, which is how it surfaced. Names are
/// unique across orgs (`project-map-doctor` fails when one resolves in two roots), so the org is
/// derivable and should not have to be typed.
///
/// The active org still wins when it holds the name unambiguously, so explicit context is never
/// overridden. When several orgs hold it, the one carrying a live `## Wave` sheet wins -- the
/// same tiebreak `lab_project_root` uses, and for the same reason: a leftover stub in one org
/// must not shadow the sheet someone is actually editing. Genuinely ambiguous stays an ERROR
/// naming the orgs, because guessing which of two live sheets you meant is how edits land in the
/// copy nothing reads.
pub(crate) fn project_dir(p: &Profile, name: &str) -> Result<PathBuf> {
    let want = name.trim().to_lowercase();

    // Fast path: the active org has it AND it is the real sheet. No other org is consulted, so
    // the common case costs exactly what it did before.
    let active = project_dir_in(p, &want);
    if let Some(dir) = &active {
        if project_tasks::task_sheet(dir).is_some() {
            return Ok(dir.clone());
        }
    }

    let mut found: Vec<(String, PathBuf)> = Vec::new();
    if let Some(dir) = active {
        found.push((p.name.clone(), dir));
    }
    for org in config::all_profile_names().unwrap_or_default() {
        if org == p.name {
            continue;
        }
        // A profile that fails to resolve is skipped, not fatal: one broken org must not make
        // every other org's projects unaddressable.
        let Ok(op) = config::resolve(Some(&org)) else {
            continue;
        };
        if let Some(dir) = project_dir_in(&op, &want) {
            found.push((org, dir));
        }
    }

    let with_sheet: Vec<(String, PathBuf, bool)> = found
        .into_iter()
        .map(|(o, d)| {
            let live = project_tasks::task_sheet(&d).is_some();
            (o, d, live)
        })
        .collect();
    choose_project_dir(name, with_sheet)
}

/// Pick between orgs that all hold the same project name. Split out from the directory walk so
/// the POLICY is testable without a config file or a vault on disk — the walk is I/O, this is
/// the decision, and the decision is the part that has been wrong before.
fn choose_project_dir(name: &str, mut found: Vec<(String, PathBuf, bool)>) -> Result<PathBuf> {
    match found.len() {
        0 => bail!("no current project named '{name}' in any org"),
        1 => Ok(found.remove(0).1),
        _ => {
            // Carrying a live `## Wave` sheet is what makes a copy the real one. 2026-08-11: a
            // stub in the always-first personal root shadowed the live sheet held by another
            // org, so writes went to the copy nothing read.
            let live: Vec<&(String, PathBuf, bool)> = found.iter().filter(|(_, _, l)| *l).collect();
            if live.len() == 1 {
                return Ok(live[0].1.clone());
            }
            let orgs: Vec<&str> = found.iter().map(|(o, _, _)| o.as_str()).collect();
            bail!(
                "'{name}' exists in {} orgs ({}) — pass --profile to say which",
                found.len(),
                orgs.join(", ")
            );
        }
    }
}

/// The reset body of a freshly-rolled (or newly-created) sheet: title, the version line,
/// and an empty current wave, NAMED for the version it will ship as.
///
/// A wave IS the patch version: a batch of fixes ships as `x.x.+1`, a release `x.+1.x`, a
/// breaking change `+1.x.x`. The heading must carry that version rather than a placeholder,
/// so one id runs from the sheet through the branch and PR to the frozen note. A wave with
/// no id of its own makes its branch, blackboard and frozen note each reach for a date.
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
/// `sheet_path` accepts `README.md` only when it declares a version, so a sheet that grew
/// organically - a `## Wave` with no version line above it - is not rollable until adopted.
///
/// The version is not invented: it opens at the next patch after the highest note in
/// `versions/`. A `Version:` line names the version currently OPEN, not the last one
/// frozen, so seeding at the max would re-open a version already frozen and the next roll
/// would write a second, different note over it. Nothing is adopted that is not already
/// being used as a wave sheet.
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

/// Did this version actually have agent work? Two sources, because the lane moved.
///
/// The agent SHEET holding any real row is the live answer: that is where an agent's working
/// state lives now. A completed legacy `#ai` row in the frozen human wave is the historical
/// one, and it stays load-bearing - versions opened before the move carry their evidence
/// only as that tag.
///
/// The pairing invariant keys off this: `agent/versions/<ver>.md` exists exactly when the
/// version has agent evidence to hold. Creating one unconditionally would file an empty note
/// for every human-only version and make an orphan report meaningless.
fn version_had_agent_work(frozen_body: &str, dir: &Path) -> bool {
    if frozen_body
        .lines()
        .any(|l| md::is_checked(l) && md::has_legacy_ai_tag(l))
    {
        return true;
    }
    fs::read_to_string(crate::agent_sheet::sheet_path(dir))
        .map(|c| {
            c.lines()
                .any(|l| md::is_task(l) && !md::task_text(l).trim().is_empty())
        })
        .unwrap_or(false)
}

/// A sheet's content with its title line and `Version:` line dropped - the part that gets
/// re-attached under a freshly written head.
fn body_after_head(content: &str) -> Vec<String> {
    content
        .lines()
        .skip(1) // the title
        .filter(|l| {
            let t = l.trim_start();
            // Both are HEAD lines the roll rebuilds. Carrying them into the body would
            // strand them under the promoted wave: `Version:` as a second, stale version
            // line, and `Agents:` as a link naming the version that just closed.
            !t.starts_with("Version:") && !t.starts_with("Agents: ")
        })
        .map(|l| l.trim_end().to_string())
        .skip_while(|l| l.trim().is_empty())
        .collect()
}

/// `notes projects --roll <name> [--minor|--major] [--force]` - close the current version
/// and open the next on the working sheet.
///
/// 1. **Gate.** A version with open tasks does not roll: closing one means its work is
///    finished, or a human moved it on with `notes ptask <name> move "<q>" --to <ver>`.
///    Without this, unchecked tasks leave the live sheet and survive only inside the
///    frozen note, on no list anyone reads. `--force` is the deliberate override.
/// 2. **Freeze.** The current wave alone goes into `versions/<vX.Y.Z>.md` (never
///    overwriting a frozen one), stamped with the epoch that bounds this version's work.
/// 3. **Pair.** The version's `agent/versions/<vX.Y.Z>.md` is created if absent, so a frozen version
///    always has its evidence note even when no AI task was tagged during it.
/// 4. **Promote.** A planned `## Wave: <next>` becomes current, carrying its tasks; the
///    rest of the roadmap carries over untouched.
///
/// No sheet means no roll: the `Version:` line is the only thing naming the open version.
pub fn roll(p: &Profile, log: &Logger, name: &str, level: Bump, force: bool) -> Result<()> {
    let dir = project_dir(p, name)?;
    let Some(sheet) = sheet_to_roll(&dir, log)? else {
        bail!("{name} has no working sheet to roll (no README.md with a `Version: vX.Y.Z` line)");
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
    // Stamp WHEN this version was frozen: that epoch is the boundary between one version's
    // work and the next, and consumers scope "what happened this version" by it. Written
    // here rather than read from the file's mtime, because regenerating an old note's
    // summary rewrites the file and would drag the boundary forward.
    let stamped = format!(
        "{frozen_body}\n<!-- rolled: {} -->\n",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    fs::write(&frozen, &stamped)?;

    // 3. the pair
    if version_had_agent_work(&frozen_body, &dir) {
        ensure_agent_note(&dir, name, &fmt_version(cur))?;
    }

    // 4. the promote
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

/// The proof text for a backfilled row: whatever the task's own marker comment recorded.
///
/// A task with no marker gets an explicit `unverified:` string rather than an empty cell,
/// so a backfilled row can never be mistaken for evidence that was actually captured.
fn backfilled_proof(line: &str) -> String {
    let trimmed = line.trim_end();
    match (trimmed.rfind("<!--"), trimmed.ends_with("-->")) {
        (Some(i), true) => {
            let inner = trimmed[i + 4..trimmed.len() - 3].trim();
            if inner.is_empty() {
                "unverified: pre-dates the proof gate".to_string()
            } else {
                inner.to_string()
            }
        }
        _ => "unverified: pre-dates the proof gate".to_string(),
    }
}

/// The date a frozen version was rolled (`<!-- rolled: EPOCH -->`), as `YYYY-MM-DD`.
/// `"-"` when the note carries no stamp, which every pre-consolidation note predates.
fn rolled_on(content: &str) -> String {
    content
        .lines()
        .rev()
        .find_map(|l| {
            let t = l.trim();
            let inner = t.strip_prefix("<!--")?.strip_suffix("-->")?.trim();
            let secs: i64 = inner.strip_prefix("rolled:")?.trim().parse().ok()?;
            chrono::DateTime::from_timestamp(secs, 0)
                .map(|d| d.with_timezone(&chrono::Local).format("%Y-%m-%d").to_string())
        })
        .unwrap_or_else(|| "-".to_string())
}

/// `notes projects --migrate <name>` - consolidate a project onto the one version layout.
///
/// Idempotent, so it is safe to re-run and safe on a project already consolidated:
///
/// 1. `ai/<ver>.md` moves to `agent/versions/<ver>.md` - the agents' half of a project
///    renamed from `ai` and given the same `README.md`-beside-`versions/` shape the
///    human's half has.
/// 2. `changelog/<ver>.md` moves to `versions/<ver>.md`, never overwriting one that
///    already exists - two records of the same version is the ambiguity being removed,
///    so a collision is an error rather than a silent pick.
/// 3. Every `versions/<ver>.md` holding completed `#ai` tasks gains its
///    `agent/versions/<ver>.md`, backfilled from each task's own marker comment.
/// 4. An emptied `changelog/` or `ai/` is removed.
///
/// Step 1 runs BEFORE step 3 on purpose: the backfill skips a version whose agent note
/// already exists, so relocating second would write a second copy of every note it had
/// just orphaned.
/// Strip the retired `#ai` tag from one sheet. Returns `(new_content, rows_touched)`.
///
/// Rows do NOT move. The tag stopped routing when the lane became a file, so every row is
/// already in the right place and this only removes a marker that now means nothing.
///
/// Every task line in the file, open and closed, in every wave - current and planned. The
/// boards render only the current wave, so sizing this off what a board shows would leave
/// the planned waves tagged and no surface would say so.
fn strip_ai_tags(content: &str) -> (String, usize) {
    let mut n = 0usize;
    let out: Vec<String> = content
        .lines()
        .map(|l| {
            if md::is_task(l) && md::has_legacy_ai_tag(l) {
                n += 1;
                md::drop_tag(l, "#ai")
            } else {
                l.to_string()
            }
        })
        .collect();
    (format!("{}\n", out.join("\n")), n)
}

/// `notes projects --retire-ai-tag [NAME] [--dry-run]` - remove the dead `#ai` tag from
/// live project sheets.
///
/// Frozen `versions/*.md` and `agent/versions/*.md` are deliberately untouched: they are
/// the evidence trail, and rewriting a record to satisfy a cosmetic rule is the opposite
/// of what it is for.
pub fn retire_ai_tag(p: &Profile, log: &Logger, name: Option<&str>, dry_run: bool) -> Result<()> {
    let dirs: Vec<(String, PathBuf)> = match name {
        Some(n) => vec![(n.to_string(), project_dir(p, n)?)],
        None => indexed(p)
            .into_iter()
            .filter_map(|(n, s)| s.parent().map(|d| (n, d.to_path_buf())))
            .collect(),
    };

    let (mut sheets, mut rows) = (0usize, 0usize);
    for (proj, dir) in dirs {
        let Some(sheet) = crate::project_tasks::task_sheet(&dir) else {
            continue;
        };
        let Ok(content) = fs::read_to_string(&sheet) else {
            continue;
        };
        let (new, n) = strip_ai_tags(&content);
        if n == 0 {
            continue;
        }
        // Rows never move, so the task-line count is invariant. Assert it rather than
        // trust it: a mangled line that stopped parsing as a task would otherwise vanish
        // from every board silently.
        let before = content.lines().filter(|l| md::is_task(l)).count();
        let after = new.lines().filter(|l| md::is_task(l)).count();
        if before != after {
            bail!(
                "{proj}: {} would change the task count ({before} -> {after}) - refusing",
                sheet.display()
            );
        }
        for l in content.lines().filter(|l| md::is_task(l) && md::has_legacy_ai_tag(l)) {
            println!("{proj}\t{}", md::task_text(l));
        }
        sheets += 1;
        rows += n;
        if !dry_run {
            md::write_atomic(&sheet, &new)?;
            log.info(
                "projects",
                &format!("retired {n} #ai tag(s) in {}", sheet.display()),
            );
        }
    }

    if rows == 0 {
        println!("no `#ai` tags on any live sheet - nothing to do");
        return Ok(());
    }
    println!("{rows} tag(s) across {sheets} sheet(s); frozen versions/ left as history");
    if dry_run {
        println!("--dry-run: nothing written");
    }
    Ok(())
}

pub fn migrate(p: &Profile, log: &Logger, name: &str) -> Result<()> {
    let dir = project_dir(p, name)?;
    let versions = dir.join("versions");
    let changelog = dir.join("changelog");

    let relocated = relocate_ai_dir(&dir)?;

    let mut moved = 0usize;
    if changelog.is_dir() {
        fs::create_dir_all(&versions)?;
        let mut srcs: Vec<PathBuf> = fs::read_dir(&changelog)?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("md"))
            .collect();
        srcs.sort();
        for src in srcs {
            let Some(fname) = src.file_name() else { continue };
            let dest = versions.join(fname);
            if dest.exists() {
                bail!(
                    "{} and {} both exist - refusing to overwrite a frozen version",
                    src.display(),
                    dest.display()
                );
            }
            fs::rename(&src, &dest)?;
            moved += 1;
        }
        if fs::read_dir(&changelog)?.next().is_none() {
            fs::remove_dir(&changelog)?;
        }
    }

    let mut backfilled = 0usize;
    let mut notes: Vec<PathBuf> = fs::read_dir(&versions)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("md"))
        .collect();
    notes.sort();
    for note in notes {
        let Some(ver) = note.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if parse_version(ver).is_none() || agent_note_path(&dir, ver).exists() {
            continue;
        }
        let content = fs::read_to_string(&note)?;
        let when = rolled_on(&content);
        let done: Vec<&str> = content
            .lines()
            .filter(|l| md::is_checked(l) && md::has_legacy_ai_tag(l))
            .collect();
        if done.is_empty() {
            continue;
        }
        for line in done {
            append_proof(&dir, name, ver, &md::task_key(line), &backfilled_proof(line), &when)?;
        }
        backfilled += 1;
    }

    log.info(
        "projects",
        &format!(
            "migrated {name}: relocated {relocated}, moved {moved}, backfilled {backfilled}"
        ),
    );
    if relocated == 0 && moved == 0 && backfilled == 0 {
        println!("{name}: already consolidated - nothing to do");
    } else {
        println!(
            "migrated {name}: {relocated} ai/ note(s) -> agent/versions/, \
             {moved} note(s) -> versions/, {backfilled} agent note(s) backfilled"
        );
    }
    Ok(())
}

/// Move a project's legacy `ai/<ver>.md` notes to `agent/versions/<ver>.md`. Returns how
/// many moved; zero for the 10 of 16 projects that never had an `ai/` dir.
///
/// A collision is an error, not a silent pick: two records of one version's agent work is
/// exactly the ambiguity this layout removes, and the old file is the one with the history.
fn relocate_ai_dir(dir: &Path) -> Result<usize> {
    let legacy = dir.join("ai");
    if !legacy.is_dir() {
        return Ok(0);
    }
    let dest_dir = agent_dir(dir).join("versions");
    let mut srcs: Vec<PathBuf> = fs::read_dir(&legacy)?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("md"))
        .collect();
    srcs.sort();

    let mut n = 0usize;
    for src in srcs {
        let Some(fname) = src.file_name() else { continue };
        let dest = dest_dir.join(fname);
        if dest.exists() {
            bail!(
                "{} and {} both exist - refusing to overwrite an agent note",
                src.display(),
                dest.display()
            );
        }
        fs::create_dir_all(&dest_dir)?;
        fs::rename(&src, &dest)?;
        n += 1;
    }
    // Only when it is genuinely empty: a stray non-md file means something else lives here
    // and deleting the dir would take it with them.
    if fs::read_dir(&legacy)?.next().is_none() {
        fs::remove_dir(&legacy)?;
    }
    Ok(n)
}

/// Every violation of the version-pairing invariant, as `"<project> <detail>"` lines.
///
/// The invariant: `agent/versions/<ver>.md` exists exactly when `versions/<ver>.md` records completed
/// `#ai` work. Both directions are findings - a version with agent work and no evidence
/// note, and an evidence note for a version that was never frozen. The OPEN version is
/// exempt in the second direction: its human side is the live sheet, not a frozen note.
/// Sheets where the roadmap's first `## Wave` does NOT name the declared `Version:`.
///
/// This is the invariant every reader leans on without checking: `project_tasks::current_wave`,
/// `board`, `/wave` and `roll_blocker` all take `sections()[0]` as the current wave. If a
/// planned section ever sorts above it, all four silently switch to work that has not started,
/// and nothing else in the system would say so.
pub fn wave_order_findings(p: &Profile) -> Vec<String> {
    let mut out = Vec::new();
    for (name, summary) in indexed(p) {
        let Some(dir) = summary.parent() else { continue };
        let Some(sheet) = sheet_path(dir) else { continue };
        let Ok(content) = fs::read_to_string(&sheet) else {
            continue;
        };
        let Some(declared) = sheet_version(&content) else {
            continue;
        };
        match crate::waves::sections(&content).first() {
            Some(first) if first.version == Some(declared) => {}
            Some(first) => out.push(format!(
                "{name}: sheet declares {} but the roadmap opens with {}",
                fmt_version(declared),
                first.label()
            )),
            None => {}
        }
    }
    out
}

pub fn pairing_findings(p: &Profile) -> Vec<String> {
    let mut out = Vec::new();
    for (name, summary) in indexed(p) {
        let Some(dir) = summary.parent() else { continue };
        let open = open_version(dir).map(fmt_version);

        let mut frozen: Vec<String> = Vec::new();
        if let Ok(entries) = fs::read_dir(dir.join("versions")) {
            for e in entries.flatten() {
                let path = e.path();
                let Some(ver) = path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if parse_version(ver).is_none() {
                    continue;
                }
                frozen.push(ver.to_string());
                let has_agent_work = fs::read_to_string(&path)
                    .map(|c| c.lines().any(|l| md::is_checked(l) && md::has_legacy_ai_tag(l)))
                    .unwrap_or(false);
                if has_agent_work && !agent_note_path(dir, ver).exists() {
                    out.push(format!("{name} {ver}: agent work frozen with no agent/ note"));
                }
            }
        }

        if let Ok(entries) = fs::read_dir(agent_dir(dir).join("versions")) {
            for e in entries.flatten() {
                let path = e.path();
                let Some(ver) = path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if parse_version(ver).is_none()
                    || frozen.iter().any(|f| f == ver)
                    || open.as_deref() == Some(ver)
                {
                    continue;
                }
                out.push(format!("{name} {ver}: agent/ note for a version never frozen"));
            }
        }
    }
    out.sort();
    out
}

/// `notes projects --version-of <name>` - print the version currently OPEN: what the
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

/// The agents' half of a project: `<project>/agent/`.
///
/// ONE name for it, so no caller spells the directory itself. Named `agent` rather than `ai`
/// because it holds the agents' WORK, not a category of technology, and because everything
/// under it mirrors the human's side of the project one level down: a live sheet at
/// `agent/README.md`, frozen waves in `agent/versions/`.
pub fn agent_dir(dir: &Path) -> PathBuf {
    dir.join("agent")
}

/// A project's frozen agent note for `ver`: `<project>/agent/versions/<vX.Y.Z>.md`.
///
/// ONE resolver, so no writer guesses the path. The agents' evidence for a version used to
/// live only on the runtime axis (`~/.agent/plans/<app>/wave-<ver>-report.md`), where the
/// human never sees it and where it is eventually archived; this puts it in the lab dir
/// beside the frozen version note it belongs to. Version-named, so a roll moves nothing.
///
/// Under `agent/versions/` rather than flat, because the live agent sheet moves in beside
/// it next: a dir mixing one live file with N frozen ones can only tell them apart by
/// parsing names. The human's side is already `README.md` beside `versions/`; this is that
/// shape, not a second convention.
pub(crate) fn agent_note_path(dir: &Path, ver: &str) -> PathBuf {
    agent_dir(dir).join("versions").join(format!("{ver}.md"))
}

/// The agent note for `ver`, created (with its `## Proof` table and `## Notes` log) if absent.
pub(crate) fn ensure_agent_note(dir: &Path, project: &str, ver: &str) -> Result<PathBuf> {
    let path = agent_note_path(dir, ver);
    if path.exists() {
        return Ok(path);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(
        &path,
        format!(
            "# {project} {ver} - agent notes\n\n\
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

/// Append a row to an agent note's `## Proof` table.
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
    let path = ensure_agent_note(dir, project, ver)?;
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

/// `notes projects --agent-note <name> [--version vX.Y.Z]` - print the path to a version's
/// agent note, creating it if absent. The seam every other writer (the wave, the cockpit's
/// roll) goes through instead of building the path themselves.
pub fn show_agent_note(p: &Profile, name: &str, version: Option<&str>) -> Result<()> {
    let dir = project_dir(p, name)?;
    let ver = match version {
        Some(v) => {
            let parsed = waves::parse(v.trim())
                .ok_or_else(|| anyhow::anyhow!("not a version: '{v}' (want vX.Y.Z)"))?;
            waves::fmt(parsed)
        }
        None => fmt_version(open_version(&dir).unwrap_or((0, 0, 1))),
    };
    let path = ensure_agent_note(&dir, name, &ver)?;
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
            // The version record lives in these. `changelog/` is the pre-consolidation
            // location, listed while any project still has one; without `versions/` and
            // `agent/` here the browser shows a project's whole version history as empty.
            //
            // `agent/` gets a second level because its frozen notes sit in
            // `agent/versions/`, mirroring the human's side. Everything else is flat.
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            match name {
                "versions" | "changelog" => collect_md(&path, name, out),
                "agent" => {
                    collect_md(&path, name, out);
                    collect_md(&path.join("versions"), "agent/versions", out);
                }
                _ => {}
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

/// Every `.md` directly in `dir`, labelled `<prefix>/<stem>`. A missing dir is no files,
/// not an error: most projects have neither `changelog/` nor a frozen agent wave yet.
fn collect_md(dir: &Path, prefix: &str, out: &mut Vec<(PathBuf, String)>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) == Some("md") {
            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            out.push((p.clone(), format!("{prefix}/{stem}")));
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

    /// A scratch project dir with no agent sheet, so `version_had_agent_work` is deciding on
    /// the frozen body alone.
    fn no_agent_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("notes-pair-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    // The boards render only the CURRENT wave, so sizing this off what a board shows would
    // leave every planned wave tagged with nothing to say so. On the live vault that is 14
    // of 34 open rows.
    #[test]
    fn the_tag_is_stripped_from_every_wave_not_just_the_current_one() {
        let sheet = "# d\nVersion: v1.13.0\n\n## Wave: v1.13.0 (current)\n\
                     - [ ] stale preview #ai #high\n\n---\n### Done\n\
                     - [x] upload 403 #ai #urgent <!-- pr:1149 -->\n\n\
                     ## Wave: v1.13.1 (planned)\n\
                     - [ ] 413 path unreachable #ai #high\n";
        let (out, n) = strip_ai_tags(sheet);
        assert_eq!(n, 3, "current + done + planned:\n{out}");
        assert!(!out.contains("#ai"), "{out}");
        // Everything else on the row survives: priority, wave position, proof stamp.
        assert!(out.contains("- [ ] stale preview #high"), "{out}");
        assert!(
            out.contains("- [x] upload 403 #urgent <!-- pr:1149 -->"),
            "{out}"
        );
        assert!(out.contains("- [ ] 413 path unreachable #high"), "{out}");
        assert!(out.contains("## Wave: v1.13.1 (planned)"), "{out}");
    }

    // NEGATIVE CONTROL: 13 of 16 live sheets carry no tag at all and must not be rewritten.
    #[test]
    fn a_sheet_with_no_ai_rows_is_reported_as_untouched() {
        let sheet = "# d\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n- [ ] plain #high\n";
        let (out, n) = strip_ai_tags(sheet);
        assert_eq!(n, 0);
        assert_eq!(out, sheet, "an untagged sheet must come back byte-identical");
    }

    // NEGATIVE CONTROL: the trap that makes this a token match and not a substring one.
    #[test]
    fn the_aid_trap_survives_the_sweep() {
        let sheet = "# d\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n\
                     - [ ] restock the first #aid kit\n";
        let (out, n) = strip_ai_tags(sheet);
        assert_eq!(n, 0);
        assert_eq!(out, sheet);
    }

    // NEGATIVE CONTROL: prose is not a task. Only checkbox rows are rewritten, so a
    // heading or a paragraph naming the tag is left exactly as written.
    #[test]
    fn prose_naming_the_tag_is_not_a_task_and_is_left_alone() {
        let sheet = "# d\nVersion: v1.0.0\nThe #ai lane is retired.\n\n\
                     ## Wave: v1.0.0 (current)\n- [ ] real row #ai\n";
        let (out, n) = strip_ai_tags(sheet);
        assert_eq!(n, 1);
        assert!(out.contains("The #ai lane is retired."), "{out}");
        assert!(out.contains("- [ ] real row\n"), "{out}");
    }

    #[test]
    fn the_sweep_is_idempotent() {
        let sheet = "# d\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n- [ ] a #ai #high\n";
        let (once, n1) = strip_ai_tags(sheet);
        let (twice, n2) = strip_ai_tags(&once);
        assert_eq!((n1, n2), (1, 0));
        assert_eq!(once, twice);
    }

    #[test]
    fn a_version_pairs_only_when_it_actually_closed_agent_work() {
        let d = no_agent_dir("legacy");
        // Completed and tagged: a version opened before the lane moved has evidence to hold.
        assert!(version_had_agent_work("- [x] ship the thing #ai\n", &d));
        // Tagged but not finished, and finished but not tagged: neither is agent evidence.
        assert!(!version_had_agent_work("- [ ] ship the thing #ai\n", &d));
        assert!(!version_had_agent_work("- [x] ship the thing\n", &d));
        // A human-only version must NOT get an empty agent note, or an orphan report that
        // reads "unpaired" stops meaning anything.
        assert!(!version_had_agent_work(
            "# d\nVersion: v1.0.0\n\n- [x] a\n- [ ] b #ai\n",
            &d
        ));
        // The `#aid` trap: a substring match here would pair a version with no agent work.
        assert!(!version_had_agent_work(
            "- [x] fix the first-aid page #aid\n",
            &d
        ));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn an_agent_sheet_with_real_work_pairs_a_version_that_carries_no_tag() {
        let d = no_agent_dir("sheet");
        fs::create_dir_all(d.join("agent")).unwrap();
        // The scaffold's empty placeholder is not work, so it must not pair a version.
        fs::write(
            d.join("agent/README.md"),
            "# d - agent board\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n- [ ] \n",
        )
        .unwrap();
        assert!(!version_had_agent_work("- [x] a human row\n", &d));

        fs::write(
            d.join("agent/README.md"),
            "# d - agent board\nVersion: v1.0.0\n\n## Wave: v1.0.0 (current)\n\
             - [x] broke the 413 path into three cases\n",
        )
        .unwrap();
        assert!(version_had_agent_work("- [x] a human row\n", &d));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn backfilled_proof_never_passes_itself_off_as_evidence() {
        assert_eq!(backfilled_proof("- [x] a #ai <!-- pr:1149 -->"), "pr:1149");
        assert_eq!(backfilled_proof("- [x] a #ai <!-- vk:634 pr:1159 -->"), "vk:634 pr:1159");
        // No marker, and an empty one, are both stated as unverified rather than blank.
        assert!(backfilled_proof("- [x] a #ai").starts_with("unverified:"));
        assert!(backfilled_proof("- [x] a #ai <!--  -->").starts_with("unverified:"));
    }

    #[test]
    fn a_frozen_notes_date_comes_from_its_roll_stamp() {
        // 2026-08-11T00:00:00Z. Asserted on the year alone: the stamp is rendered in local
        // time, so the day can legitimately differ by one from the UTC date.
        assert!(rolled_on("body\n<!-- rolled: 1786492800 -->\n").starts_with("2026-"));
        // A note frozen before the stamp existed has no date to claim.
        assert_eq!(rolled_on("body with no stamp\n"), "-");
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
        assert_eq!(path, agent_note_path(&dir, "v1.13.0"));
        let _ = fs::remove_dir_all(&dir);
    }

    /// A scratch project dir, unique per test and per thread.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "proj-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn an_agent_note_lands_under_agent_versions_not_flat() {
        // The shape the live agent sheet moves in beside: `agent/README.md` next to
        // `agent/versions/`. A flat `agent/<ver>.md` would put them in one dir.
        let dir = Path::new("/p");
        assert_eq!(
            agent_note_path(dir, "v1.13.0"),
            Path::new("/p/agent/versions/v1.13.0.md")
        );
    }

    #[test]
    fn the_legacy_ai_dir_relocates_and_is_removed() {
        let dir = scratch("reloc");
        fs::create_dir_all(dir.join("ai")).unwrap();
        fs::write(dir.join("ai/v1.0.0.md"), "# old note\n").unwrap();
        fs::write(dir.join("ai/v1.1.0.md"), "# newer\n").unwrap();

        assert_eq!(relocate_ai_dir(&dir).unwrap(), 2);
        assert_eq!(
            fs::read_to_string(dir.join("agent/versions/v1.0.0.md")).unwrap(),
            "# old note\n",
            "content moves, not just the name"
        );
        assert!(dir.join("agent/versions/v1.1.0.md").exists());
        assert!(!dir.join("ai").exists(), "the emptied dir is removed");

        // Idempotent: a second run has nothing to do and must not fail.
        assert_eq!(relocate_ai_dir(&dir).unwrap(), 0);
        let _ = fs::remove_dir_all(&dir);
    }

    // THE NEGATIVE CONTROL. 10 of 16 live projects have no `ai/` dir at all, and the two
    // Gigantic sheets are deliberately not on this model - a migration that touches them is
    // a migration that ran on files it was never pointed at.
    #[test]
    fn a_project_with_no_ai_dir_is_left_completely_alone() {
        let dir = scratch("noai");
        fs::write(dir.join("README.md"), "# demo\nVersion: v0.1.0\n").unwrap();
        fs::create_dir_all(dir.join("versions")).unwrap();
        fs::write(dir.join("versions/v0.0.1.md"), "# frozen\n").unwrap();

        assert_eq!(relocate_ai_dir(&dir).unwrap(), 0);
        assert!(!dir.join("agent").exists(), "no dir conjured out of nothing");
        assert!(dir.join("versions/v0.0.1.md").exists());
        assert_eq!(
            fs::read_to_string(dir.join("README.md")).unwrap(),
            "# demo\nVersion: v0.1.0\n",
            "the human's sheet is not a migration target"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_non_md_file_keeps_the_legacy_dir_alive() {
        // Removing the dir would take the stray file with it.
        let dir = scratch("stray");
        fs::create_dir_all(dir.join("ai")).unwrap();
        fs::write(dir.join("ai/v1.0.0.md"), "# note\n").unwrap();
        fs::write(dir.join("ai/scratch.txt"), "not mine to move\n").unwrap();

        assert_eq!(relocate_ai_dir(&dir).unwrap(), 1);
        assert!(dir.join("ai/scratch.txt").exists(), "stray file survives");
        assert!(dir.join("agent/versions/v1.0.0.md").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_collision_is_an_error_rather_than_a_silent_overwrite() {
        // The old file carries the history; picking one silently is how a version ends up
        // with two disagreeing agent records, which is what this layout exists to prevent.
        let dir = scratch("collide");
        fs::create_dir_all(dir.join("ai")).unwrap();
        fs::create_dir_all(dir.join("agent/versions")).unwrap();
        fs::write(dir.join("ai/v1.0.0.md"), "# the one with history\n").unwrap();
        fs::write(dir.join("agent/versions/v1.0.0.md"), "# newer, empty\n").unwrap();

        assert!(relocate_ai_dir(&dir).is_err());
        assert_eq!(
            fs::read_to_string(dir.join("ai/v1.0.0.md")).unwrap(),
            "# the one with history\n",
            "nothing is moved on the failing path"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_browser_reaches_a_frozen_agent_note_two_levels_down() {
        // `agent/versions/` is deeper than every other note dir; without the second hop the
        // browser shows a project's agent history as empty.
        let dir = scratch("browse");
        fs::write(dir.join("README.md"), "# demo\n").unwrap();
        fs::create_dir_all(dir.join("agent/versions")).unwrap();
        fs::write(dir.join("agent/README.md"), "# demo - agent board\n").unwrap();
        fs::write(dir.join("agent/versions/v1.0.0.md"), "# frozen\n").unwrap();

        let mut out = Vec::new();
        collect_project_files(&dir, &mut out);
        let labels: Vec<&str> = out.iter().map(|(_, l)| l.as_str()).collect();
        assert!(labels.contains(&"README"), "{labels:?}");
        assert!(labels.contains(&"agent/README"), "{labels:?}");
        assert!(labels.contains(&"agent/versions/v1.0.0"), "{labels:?}");
        let _ = fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod marker_tests {
    use super::*;

    const SUMMARY: &str = "---\nid: summary\n---\n\n# demo\n\
<!-- cockpit: repo=bnb-platform vikunja=3 pathfilter=apps/demo branch=develop -->\n\n\
body\n";

    #[test]
    fn reads_a_key_and_distinguishes_absent_from_empty() {
        assert_eq!(marker_key(SUMMARY, "repo").as_deref(), Some("bnb-platform"));
        assert_eq!(marker_key(SUMMARY, "stage"), None);
        let empty = SUMMARY.replace("vikunja=3", "vikunja=");
        assert_eq!(marker_key(&empty, "vikunja").as_deref(), Some(""));
    }

    /// A prefix must not match: reading `repo` from a marker carrying only `release-epic`
    /// would otherwise invent a value.
    #[test]
    fn does_not_match_a_key_that_merely_contains_the_name() {
        let m = "<!-- cockpit: release-epic=29 prfilter=demo -->";
        assert_eq!(marker_key(m, "epic"), None);
        assert_eq!(marker_key(m, "filter"), None);
        assert_eq!(marker_key(m, "release-epic").as_deref(), Some("29"));
    }

    #[test]
    fn appends_an_absent_key_and_keeps_every_sibling_in_order() {
        let out = set_marker_key(SUMMARY, "stage", "prod").unwrap();
        let line = out.lines().find(|l| l.contains("cockpit:")).unwrap();
        assert_eq!(
            line,
            "<!-- cockpit: repo=bnb-platform vikunja=3 pathfilter=apps/demo branch=develop stage=prod -->"
        );
        assert!(out.starts_with("---\nid: summary\n"));
        assert!(out.ends_with("body\n"), "trailing newline preserved");
    }

    #[test]
    fn rewrites_an_existing_key_in_place() {
        let once = set_marker_key(SUMMARY, "stage", "draft").unwrap();
        let twice = set_marker_key(&once, "stage", "beta").unwrap();
        assert_eq!(marker_key(&twice, "stage").as_deref(), Some("beta"));
        assert_eq!(twice.matches("stage=").count(), 1, "no duplicate key");
        assert_eq!(marker_key(&twice, "repo").as_deref(), Some("bnb-platform"));
    }

    /// Writing the same value twice must produce byte-identical output, or the index
    /// watcher (which fires on a changed file) would retrigger on every sync.
    #[test]
    fn setting_the_same_value_is_a_no_op() {
        let once = set_marker_key(SUMMARY, "stage", "alpha").unwrap();
        assert_eq!(set_marker_key(&once, "stage", "alpha").unwrap(), once);
    }

    #[test]
    fn a_summary_with_no_marker_is_an_error_not_a_silent_no_op() {
        let err = set_marker_key("# demo\n\nno marker here\n", "stage", "prod").unwrap_err();
        assert!(err.to_string().contains("cockpit"), "{err}");
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
    fn a_roll_does_not_strand_the_agents_link_under_the_new_wave() {
        // `Agents:` is a HEAD line, derived from `Version:`. Carried into the body it would
        // sit below the promoted wave naming the version that just closed - wrong, and in
        // the wrong place. `agent_sheet::with_link` re-stamps the correct one afterwards.
        let sheet = "\
# demo
Version: v1.13.0
Agents: [[lab/p/demo/agent/README|agent board]] - [[lab/projects/agent-board|all projects]]

## Wave: v1.13.0 (current)
- [x] shipped

## Wave: v1.14.0 (planned)
- [ ] next thing
";
        let (frozen, rolled) = rebuild_sheet(sheet, (1, 13, 0), (1, 14, 0));
        assert_eq!(
            rolled.matches("Agents: ").count(),
            0,
            "the stale link is dropped, not relocated:\n{rolled}"
        );
        assert!(rolled.contains("Version: v1.14.0"), "{rolled}");
        assert!(rolled.contains("## Wave: v1.14.0 (current)"), "{rolled}");
        assert!(rolled.contains("next thing"), "the promoted wave survives:\n{rolled}");
        assert_eq!(
            frozen.matches("Agents: ").count(),
            0,
            "nor does it land in the release record:\n{frozen}"
        );
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
        // The organically-grown sheet: a `## Wave` the human has been adding to, with no
        // `Version:` line, on a project whose earlier versions are already frozen.
        let tmp = std::env::temp_dir().join(format!("notes-adopt-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("versions")).unwrap();
        fs::write(tmp.join("versions/v1.9.0.md"), "").unwrap();
        fs::write(tmp.join("versions/v1.10.0.md"), "").unwrap();
        let sheet = "# alpha\n\n## Wave: new (current)\n- [ ] a bug\n";
        fs::write(tmp.join("README.md"), sheet).unwrap();

        assert!(sheet_path(&tmp).is_none(), "no Version: line yet");
        let log = Logger::new(tmp.join("log"), false);
        let got = sheet_to_roll(&tmp, &log).unwrap();
        assert_eq!(got, Some(tmp.join("README.md")));

        let after = fs::read_to_string(tmp.join("README.md")).unwrap();
        // The NEXT patch after the highest frozen version, not that version itself: a
        // sheet's `Version:` names the version still open. Seeding at v1.10.0 would
        // re-open one already frozen, and the next roll would freeze a second, different
        // v1.10.0 over it.
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
        // The live shape this was found in: earlier versions frozen in `versions/`, no
        // `Version:` line, and v1.10.0 already TAGGED and in the app's CHANGELOG. A wave
        // reading that back would name its branch, board and frozen note after a release
        // that has already gone out, then freeze a second, different v1.10.0.
        let tmp = std::env::temp_dir().join(format!("notes-open-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("versions")).unwrap();
        fs::write(tmp.join("versions/v1.9.0.md"), "").unwrap();
        fs::write(tmp.join("versions/v1.10.0.md"), "").unwrap();

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
        fs::create_dir_all(tmp.join("versions")).unwrap();
        fs::write(tmp.join("versions/v1.10.0.md"), "").unwrap();
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

    // --- cross-org name resolution -------------------------------------------------------
    // A project used to be addressable only inside the active org, so `notes ptask <name>`
    // needed a --profile whose right value you memorised per project -- and a keybinding cannot
    // supply one.

    fn cand(org: &str, dir: &str, live: bool) -> (String, PathBuf, bool) {
        (org.to_string(), PathBuf::from(dir), live)
    }

    #[test]
    fn one_org_holds_it_so_no_flag_is_needed() {
        let got = choose_project_dir("pmp", vec![cand("bnb", "/v/lab/bnb/projects/current/pmp", true)]);
        assert_eq!(got.unwrap(), PathBuf::from("/v/lab/bnb/projects/current/pmp"));
    }

    /// The 2026-08-11 failure, as a test: a stub in one org must not shadow the sheet someone is
    /// actually editing in another. Same tiebreak `lab_project_root` uses on the shell side.
    #[test]
    fn a_stub_never_shadows_the_org_carrying_the_live_sheet() {
        let got = choose_project_dir(
            "pmp",
            vec![
                cand("personal", "/v/lab/projects/current/pmp", false), // stub, no wave
                cand("bnb", "/v/lab/bnb/projects/current/pmp", true),   // the real sheet
            ],
        );
        assert_eq!(got.unwrap(), PathBuf::from("/v/lab/bnb/projects/current/pmp"));
    }

    /// Two live sheets is genuinely ambiguous, and guessing is how an edit lands in the copy
    /// nothing reads. Refuse, and NAME the orgs so the fix is obvious.
    #[test]
    fn two_live_sheets_is_an_error_that_names_the_orgs() {
        let err = choose_project_dir(
            "pmp",
            vec![
                cand("personal", "/v/a/pmp", true),
                cand("bnb", "/v/b/pmp", true),
            ],
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("personal"), "names the orgs: {err}");
        assert!(err.contains("bnb"), "names the orgs: {err}");
        assert!(err.contains("--profile"), "says how to disambiguate: {err}");
    }

    /// Duplicated with NO live sheet anywhere is still ambiguous -- silently picking the first
    /// would be the old first-root-wins bug with extra steps.
    #[test]
    fn duplicated_stubs_with_no_sheet_are_still_refused() {
        assert!(choose_project_dir(
            "pmp",
            vec![cand("personal", "/v/a/pmp", false), cand("bnb", "/v/b/pmp", false)],
        )
        .is_err());
    }

    #[test]
    fn no_org_holds_it_says_so() {
        let err = choose_project_dir("ghost", vec![]).unwrap_err().to_string();
        assert!(err.contains("ghost") && err.contains("any org"), "{err}");
    }
}
