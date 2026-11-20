//! Repo docs in the knowledge hubs: the domain each exported `.repos/` doc routes to, and the
//! generated `## Repo docs` section of that hub that links it. The docs stay in their repos.
//!
//! A doc routes by the most specific `repo_docs` glob in `domains.toml`, else the project domain
//! the project map says covers it, else the core domain whose `canonical` is nearest in the same
//! checkout. A doc no domain routes is the lint class `repo_doc_unrouted`.
//!
//! The section is owned by the `- [[.repos/` bullet predicate (as `agent_sheet::with_head` owns
//! its head lines); a human line there stays. A machine owns only the bullets of checkouts it has
//! exported, so a partial export (or none, like the phone) never strips another machine's.

use crate::agent_sheet::EXPORT_DIR;
use crate::config::Profile;
use crate::knowledge_registry::{self as registry, Domain, Kind, Registry, INDEX};
use crate::logging::Logger;
use crate::md;
use anyhow::Result;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// The hub section this module owns.
const HEADING: &str = "## Repo docs";

/// A doc named by a path under `.repos/`: `<checkout>/<path in the repo>`.
fn split(doc: &str) -> (&str, &str) {
    doc.split_once('/').unwrap_or((doc, ""))
}

fn dir_of(rel: &str) -> Vec<&str> {
    let mut parts: Vec<&str> = rel.split('/').collect();
    parts.pop();
    parts
}

/// `pat` against `s`, one `/`-separated segment at a time: `*` is any run of characters inside a
/// segment, `**` is any number of segments (none included).
pub fn glob(pat: &str, s: &str) -> bool {
    fn segment(pat: &str, s: &str) -> bool {
        let parts: Vec<&str> = pat.split('*').collect();
        let (first, rest) = (parts[0], &parts[1..]);
        let Some(mut at) = s.strip_prefix(first) else {
            return false;
        };
        let Some((last, middle)) = rest.split_last() else {
            return at.is_empty();
        };
        for m in middle {
            match at.find(m) {
                Some(i) => at = &at[i + m.len()..],
                None => return false,
            }
        }
        at.ends_with(last) && at.len() >= last.len()
    }
    fn walk(pat: &[&str], s: &[&str]) -> bool {
        match pat.split_first() {
            None => s.is_empty(),
            Some((&"**", rest)) => (0..=s.len()).any(|i| walk(rest, &s[i..])),
            Some((p, rest)) => s
                .split_first()
                .is_some_and(|(h, t)| segment(p, h) && walk(rest, t)),
        }
    }
    let pat: Vec<&str> = pat.split('/').collect();
    let s: Vec<&str> = s.split('/').collect();
    walk(&pat, &s)
}

/// How much of a glob is literal: the more specific of two matching globs has more of it.
fn specificity(pat: &str) -> usize {
    pat.chars().filter(|c| !matches!(c, '*' | '/')).count()
}

/// What a project domain covers inside one checkout.
#[derive(Debug, Clone, PartialEq)]
struct Cover {
    checkout: String,
    /// The project's folder in the repo; empty for a whole repo.
    sub: String,
    /// A game inside a repo of many: only its `docs/games/<id>*.md` docs, the convention
    /// `agent_sheet::repo_docs` exports them by.
    game: Option<String>,
}

impl Cover {
    /// How closely this covers `doc` (`<checkout>/<path>`), None when it does not. A game's own
    /// docs beat a folder, and a folder beats the whole repo.
    fn score(&self, doc: &str) -> Option<usize> {
        let (checkout, rel) = split(doc);
        if checkout != self.checkout {
            return None;
        }
        if let Some(id) = &self.game {
            let own = ["", "-story", "-look"]
                .iter()
                .any(|s| rel == format!("docs/games/{id}{s}.md"));
            return own.then_some(usize::MAX);
        }
        if self.sub.is_empty() {
            return Some(0);
        }
        (rel == format!("{}/README.md", self.sub) || rel.starts_with(&format!("{}/", self.sub)))
            .then_some(self.sub.len() + 1)
    }
}

/// The facts of the project map routing needs, resolved once: no project-map lookup runs per doc,
/// so the rules are tested without one.
#[derive(Debug, Default)]
pub struct Facts {
    /// A project domain's id with what it covers.
    projects: Vec<(String, Cover)>,
    /// A core domain's id with each canonical doc as `<checkout>/<path>`, where it has one.
    core: Vec<(String, Vec<String>)>,
}

impl Facts {
    /// Read the project map for each project and core domain of `reg`. A domain the map does not
    /// resolve contributes nothing, so its docs fall through to the next rule.
    pub fn load(reg: &Registry, map: Option<&project_map::Registry>) -> Facts {
        let mut facts = Facts::default();
        let Some(map) = map else {
            return facts;
        };
        let home = std::env::var("HOME").unwrap_or_default();
        for d in &reg.domain {
            match d.kind() {
                Kind::Project => {
                    if let Some(c) = project_cover(map, d.leaf()) {
                        facts.projects.push((d.id.clone(), c));
                    }
                }
                Kind::Core => {
                    let docs: Vec<String> = d
                        .canonical
                        .iter()
                        .filter_map(|c| {
                            let abs = match c.strip_prefix("~/") {
                                Some(rest) => format!("{home}/{rest}"),
                                None => c.clone(),
                            };
                            canonical_doc(map, &abs)
                        })
                        .collect();
                    if !docs.is_empty() {
                        facts.core.push((d.id.clone(), docs));
                    }
                }
                _ => {}
            }
        }
        facts
    }
}

fn project_cover(map: &project_map::Registry, name: &str) -> Option<Cover> {
    let project = map.lookup(name)?;
    let kind = map.kind(project)?;
    let (_, checkout) = crate::agent_sheet::project_checkout(map, project)?;
    let sub = map
        .tracker(project)
        .and_then(|t| t.get("path")?.as_str())
        .unwrap_or("")
        .trim_matches('/')
        .to_string();
    match kind.as_str() {
        "game" if !sub.is_empty() => Some(Cover {
            checkout,
            game: Path::new(&sub)
                .file_name()
                .map(|n| n.to_string_lossy().to_lowercase()),
            sub,
        }),
        "game" | "app" | "infra" => Some(Cover {
            checkout,
            sub,
            game: None,
        }),
        _ => None,
    }
}

/// A canonical doc at an absolute path as `<checkout>/<path in the repo>`, None when it is not in
/// a registered checkout (a doc under `~/.local/src/docs` may sit in none).
fn canonical_doc(map: &project_map::Registry, abs: &str) -> Option<String> {
    // The map resolves a directory, not a file.
    let project = map.project_for_path(&Path::new(abs).parent()?.to_string_lossy());
    let (dir, name) = crate::agent_sheet::project_checkout(map, &project)?;
    let rel = Path::new(abs).strip_prefix(&dir).ok()?;
    Some(format!("{name}/{}", rel.to_string_lossy()))
}

/// The id of the domain that routes `doc` (`<checkout>/<path>`), or None.
pub fn route<'a>(reg: &'a Registry, facts: &'a Facts, doc: &str) -> Option<&'a str> {
    // The first of equals wins, so the registry's order decides a tie.
    let best = |scores: Vec<(&'a str, usize)>| {
        scores
            .into_iter()
            .fold(None, |best: Option<(&str, usize)>, (id, s)| match best {
                Some((_, b)) if b >= s => best,
                _ => Some((id, s)),
            })
            .map(|(id, _)| id)
    };
    let globbed = reg
        .domain
        .iter()
        .flat_map(|d| {
            d.repo_docs
                .iter()
                .filter(|g| glob(g, doc))
                .map(|g| (d.id.as_str(), specificity(g)))
        })
        .collect();
    if let Some(id) = best(globbed) {
        return Some(id);
    }
    let projects = facts
        .projects
        .iter()
        .filter_map(|(id, c)| Some((id.as_str(), c.score(doc)?)))
        .collect();
    if let Some(id) = best(projects) {
        return Some(id);
    }
    let (checkout, rel) = split(doc);
    let doc_dir = dir_of(rel);
    let core = facts
        .core
        .iter()
        .filter_map(|(id, docs)| {
            let score = docs
                .iter()
                .filter_map(|c| {
                    let (co, crel) = split(c);
                    if co != checkout {
                        return None;
                    }
                    // A canonical whose folder holds the doc is nearer than one beside it.
                    let cdir = dir_of(crel);
                    let holds = doc_dir.len() >= cdir.len() && doc_dir[..cdir.len()] == cdir[..];
                    Some(if holds { cdir.len() + 1 } else { 0 })
                })
                .max()?;
            Some((id.as_str(), score))
        })
        .collect();
    best(core)
}

/// Every markdown doc exported under `<vault>/.repos/`, as `<checkout>/<path>`, sorted. A hidden
/// folder (`.stamps`) is skipped below a checkout; the checkout itself may be one (`.dotfiles`).
pub fn exported(vault: &Path) -> Vec<String> {
    fn walk(dir: &Path, rel: &str, out: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let path = format!("{rel}/{name}");
            let Ok(kind) = e.file_type() else { continue };
            if kind.is_dir() && !name.starts_with('.') {
                walk(&e.path(), &path, out);
            } else if kind.is_file() && name.to_lowercase().ends_with(".md") {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    for c in checkouts(vault) {
        walk(&vault.join(EXPORT_DIR).join(&c), &c, &mut out);
    }
    out.sort();
    out
}

/// The checkouts this machine has exported.
fn checkouts(vault: &Path) -> BTreeSet<String> {
    fs::read_dir(vault.join(EXPORT_DIR))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect()
}

/// The exported docs no domain routes, for the lint.
pub fn unrouted(p: &Profile, reg: &Registry) -> Vec<String> {
    let docs = exported(&p.vault);
    if docs.is_empty() {
        return Vec::new();
    }
    let facts = Facts::load(reg, project_map::cached().as_deref());
    docs.into_iter()
        .filter(|d| route(reg, &facts, d).is_none())
        .collect()
}

/// The doc's first `# ` heading, else its file name without `.md`, made safe inside a wikilink.
fn title(vault: &Path, doc: &str) -> String {
    let text = fs::read_to_string(vault.join(EXPORT_DIR).join(doc)).unwrap_or_default();
    let body = match text
        .strip_prefix("---\n")
        .and_then(|t| t.split_once("\n---"))
    {
        Some((_, rest)) => rest,
        None => &text,
    };
    let mut fenced = false;
    let heading = body
        .lines()
        .filter(|l| {
            if l.trim_start().starts_with("```") || l.trim_start().starts_with("~~~") {
                fenced = !fenced;
                return false;
            }
            !fenced
        })
        .find_map(|l| l.strip_prefix("# "))
        .map(|h| h.replace(['[', ']', '|'], " "))
        .map(|h| h.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|h| !h.is_empty());
    heading.unwrap_or_else(|| {
        let name = doc.rsplit('/').next().unwrap_or(doc);
        name.strip_suffix(".md").unwrap_or(name).to_string()
    })
}

/// The bullet for one doc: the link target keeps the export path's case and drops `.md`.
fn bullet(vault: &Path, doc: &str) -> String {
    let target = doc.strip_suffix(".md").unwrap_or(doc);
    format!("- [[{EXPORT_DIR}/{target}|{}]]", title(vault, doc))
}

/// A bullet this module writes: one `[[.repos/...]]` link and nothing else.
fn is_owned(line: &str) -> bool {
    let t = line.trim();
    t.starts_with(&owned_prefix()) && t.ends_with("]]") && t.matches("]]").count() == 1
}

fn owned_prefix() -> String {
    format!("- [[{EXPORT_DIR}/")
}

/// The checkout an owned bullet links.
fn bullet_checkout(line: &str) -> &str {
    let rest = line.trim().trim_start_matches(owned_prefix().as_str());
    rest.split('/').next().unwrap_or("")
}

/// A hub's content with its `## Repo docs` section holding `bullets` (the docs of the checkouts
/// this machine has exported) plus the bullets of other checkouts already there, sorted, ahead of
/// whatever else a human wrote in it. None when nothing changes.
///
/// The section is removed when it would be empty, and appended when it is missing. A bullet of a
/// checkout not in `local` is kept as it is.
pub fn with_section(content: &str, bullets: &[String], local: &BTreeSet<String>) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.iter().position(|l| l.trim_end() == HEADING);
    let end = start.map_or(lines.len(), |s| {
        lines[s + 1..]
            .iter()
            .position(|l| l.starts_with("## "))
            .map_or(lines.len(), |i| s + 1 + i)
    });
    let section: &[&str] = start.map_or(&[], |s| &lines[s + 1..end]);

    let mut owned: Vec<String> = bullets.to_vec();
    let mut human: Vec<&str> = Vec::new();
    for l in section {
        if is_owned(l) {
            if !local.contains(bullet_checkout(l)) {
                owned.push(l.trim().to_string());
            }
        } else {
            human.push(l);
        }
    }
    owned.sort();
    owned.dedup();
    while human.first().is_some_and(|l| l.trim().is_empty()) {
        human.remove(0);
    }
    while human.last().is_some_and(|l| l.trim().is_empty()) {
        human.pop();
    }

    let before = &lines[..start.unwrap_or(lines.len())];
    let after = &lines[end.min(lines.len())..];
    let mut out: Vec<String> = before.iter().map(|l| l.to_string()).collect();
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    if !owned.is_empty() || !human.is_empty() {
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push(HEADING.to_string());
        out.push(String::new());
        out.extend(owned);
        if !human.is_empty() {
            out.push(String::new());
            out.extend(human.iter().map(|l| l.to_string()));
        }
    }
    if !after.is_empty() {
        out.push(String::new());
        out.extend(after.iter().map(|l| l.to_string()));
    }
    let out = format!("{}\n", out.join("\n"));
    (out != content).then_some(out)
}

/// Rewrite the `## Repo docs` section of every hub from what is exported now. Writes only a hub
/// that changes; a hub that does not exist is not made (`domain add` makes it). Returns the hubs
/// written. A vault with no registry or no export has nothing to do.
pub fn refresh(p: &Profile, log: &Logger) -> Result<Vec<PathBuf>> {
    let Some(reg) = registry::load(p)? else {
        return Ok(Vec::new());
    };
    let local = checkouts(&p.vault);
    if local.is_empty() {
        return Ok(Vec::new());
    }
    let facts = Facts::load(&reg, project_map::cached().as_deref());
    let mut by_domain: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for doc in exported(&p.vault) {
        if let Some(id) = route(&reg, &facts, &doc) {
            by_domain
                .entry(id)
                .or_default()
                .push(bullet(&p.vault, &doc));
        }
    }
    let mut wrote = Vec::new();
    for d in &reg.domain {
        let hub = p.knowledge.join(&d.id).join(INDEX);
        let bullets = by_domain.remove(d.id.as_str()).unwrap_or_default();
        let Ok(content) = fs::read_to_string(&hub) else {
            if !bullets.is_empty() {
                log.warn(
                    "knowledge",
                    &format!("{} has no hub to link {} repo docs", d.id, bullets.len()),
                );
            }
            continue;
        };
        if let Some(new) = with_section(&content, &bullets, &local) {
            md::write_atomic(&hub, &new)?;
            log.info("knowledge", &format!("repo docs refreshed in {}", d.id));
            wrote.push(hub);
        }
    }
    Ok(wrote)
}

/// Domains whose `repo_docs` the registry rules check: each is `<checkout>/<glob>`, in the
/// checkout's own spelling, no `..`.
pub fn check_pattern(d: &Domain, pat: &str) -> std::result::Result<(), String> {
    let bad = |why: &str| Err(format!("domain `{}`: repo_docs `{pat}` {why}", d.id));
    let Some((checkout, rest)) = pat.split_once('/') else {
        return bad("is not `<checkout>/<glob>`");
    };
    if checkout.is_empty() || checkout.contains(['*', '?']) || rest.is_empty() {
        return bad("needs a literal checkout and a path");
    }
    if pat
        .split('/')
        .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return bad("has an empty, `.` or `..` segment");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn d(id: &str, canonical: &[&str], repo_docs: &[&str]) -> Domain {
        Domain {
            id: id.into(),
            is: "what goes here".into(),
            aliases: Vec::new(),
            canonical: canonical.iter().map(|s| s.to_string()).collect(),
            repo_docs: repo_docs.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn cover(checkout: &str, sub: &str, game: Option<&str>) -> Cover {
        Cover {
            checkout: checkout.into(),
            sub: sub.into(),
            game: game.map(str::to_string),
        }
    }

    fn facts() -> Facts {
        Facts {
            projects: vec![
                ("projects/playground".into(), cover("pg", "", None)),
                (
                    "projects/dodgin".into(),
                    cover("pg", "Assets/Dodgin", Some("dodgin")),
                ),
                ("projects/pmp".into(), cover("platform", "apps/pmp", None)),
            ],
            core: vec![
                (
                    "core/mobile".into(),
                    vec!["platform/docs/deployment/MOBILE.md".into()],
                ),
                ("core/web".into(), vec!["platform/docs/README.md".into()]),
                ("core/infra".into(), vec!["home/docs/README.md".into()]),
                ("core/ops".into(), vec!["home/README.md".into()]),
            ],
        }
    }

    fn reg(globs: &[(&str, &[&str])]) -> Registry {
        let mut domain: Vec<Domain> = [
            "core/mobile",
            "core/web",
            "core/infra",
            "core/ops",
            "projects/playground",
            "projects/dodgin",
            "projects/pmp",
            "subjects/finance",
        ]
        .iter()
        .map(|id| d(id, &[], &[]))
        .collect();
        for (id, g) in globs {
            domain.iter_mut().find(|x| x.id == *id).unwrap().repo_docs =
                g.iter().map(|s| s.to_string()).collect();
        }
        Registry { domain }
    }

    #[test]
    fn a_glob_matches_by_segment() {
        assert!(glob("home/docs/finance/**", "home/docs/finance/a.md"));
        assert!(glob("home/docs/finance/**", "home/docs/finance/x/y.md"));
        assert!(!glob("home/docs/finance/**", "home/docs/financex/a.md"));
        assert!(glob("home/docs/*.md", "home/docs/a.md"));
        assert!(!glob("home/docs/*.md", "home/docs/x/a.md"));
        assert!(glob("home/**/ci.md", "home/docs/runbooks/ci.md"));
        assert!(glob("home/docs/a*c.md", "home/docs/abc.md"));
        assert!(!glob("home/docs/a*c.md", "home/docs/ab.md"));
        assert!(glob("home/docs/a.md", "home/docs/a.md"));
        assert!(!glob("home/docs/a.md", "home/docs/a.mdx"));
    }

    #[test]
    fn a_doc_routes_glob_then_project_then_core() {
        let r = reg(&[("subjects/finance", &["home/docs/finance/**"])]);
        let f = facts();
        let at = |doc: &str| route(&r, &f, doc);
        // 1. the glob wins over the core domain that also lives in the checkout
        assert_eq!(at("home/docs/finance/budget.md"), Some("subjects/finance"));
        // 3. a core domain's checkout
        assert_eq!(at("home/docs/nut-ups.md"), Some("core/infra"));
        // 2. a project folder, over the core domain of the same checkout
        assert_eq!(at("platform/apps/pmp/docs/a.md"), Some("projects/pmp"));
        // the nearest canonical folder wins inside one checkout, not the registry order
        assert_eq!(at("platform/docs/x.md"), Some("core/web"));
        assert_eq!(at("platform/docs/deployment/y.md"), Some("core/mobile"));
        // a game's own docs beat the whole-repo project
        assert_eq!(at("pg/docs/games/dodgin-story.md"), Some("projects/dodgin"));
        assert_eq!(at("pg/docs/games/other.md"), Some("projects/playground"));
        // nothing covers a checkout no domain knows
        assert_eq!(at("elsewhere/README.md"), None);
    }

    #[test]
    fn the_most_specific_glob_wins_and_dropping_an_override_reroutes() {
        let f = facts();
        let both = reg(&[
            ("subjects/finance", &["home/docs/**"]),
            ("core/ops", &["home/docs/unity-ci.md"]),
        ]);
        assert_eq!(route(&both, &f, "home/docs/unity-ci.md"), Some("core/ops"));
        assert_eq!(route(&both, &f, "home/docs/a.md"), Some("subjects/finance"));
        // negative control: without the override the doc falls to the default domain
        let without = reg(&[("subjects/finance", &["home/docs/**"])]);
        assert_eq!(
            route(&without, &f, "home/docs/unity-ci.md"),
            Some("subjects/finance")
        );
        let none = reg(&[]);
        assert_eq!(
            route(&none, &f, "home/docs/unity-ci.md"),
            Some("core/infra")
        );
    }

    #[test]
    fn a_pattern_is_a_checkout_and_a_glob() {
        let dom = d("core/ops", &[], &[]);
        for ok in ["home/docs/a.md", "home/docs/**", ".dotfiles/docs/*.md"] {
            assert!(check_pattern(&dom, ok).is_ok(), "{ok}");
        }
        for bad in [
            "home",
            "home/",
            "*/docs/a.md",
            "home/../a.md",
            "home//a.md",
            "/a.md",
        ] {
            assert!(check_pattern(&dom, bad).is_err(), "{bad}");
        }
    }

    fn human_section() -> String {
        "# Hub\n\nintro\n\n## Repo docs\n\n- [[.repos/home/docs/old|Old]]\n- [[.repos/phone/docs/x|X]]\n\nmy note\n\n## Other\n\ntext\n".to_string()
    }

    #[test]
    fn the_section_keeps_human_lines_and_other_machines_bullets() {
        let local: BTreeSet<String> = ["home".to_string()].into();
        let new = vec!["- [[.repos/home/docs/new|New]]".to_string()];
        let out = with_section(&human_section(), &new, &local).unwrap();
        assert_eq!(
            out,
            "# Hub\n\nintro\n\n## Repo docs\n\n- [[.repos/home/docs/new|New]]\n- [[.repos/phone/docs/x|X]]\n\nmy note\n\n## Other\n\ntext\n"
        );
        // a removed doc drops its bullet (`old`); the `phone` checkout is not exported here, so
        // its bullet stays; the human line stays
        assert!(!out.contains("Old"));
        assert!(with_section(&out, &new, &local).is_none(), "idempotent");
    }

    #[test]
    fn the_section_is_added_and_removed_whole() {
        let local: BTreeSet<String> = ["home".to_string()].into();
        let hub = "# Hub\n\nintro\n";
        let new = vec!["- [[.repos/home/a|A]]".to_string()];
        let added = with_section(hub, &new, &local).unwrap();
        assert_eq!(
            added,
            "# Hub\n\nintro\n\n## Repo docs\n\n- [[.repos/home/a|A]]\n"
        );
        assert!(with_section(&added, &new, &local).is_none());
        let gone = with_section(&added, &[], &local).unwrap();
        assert_eq!(gone, hub);
        // no docs and no section: nothing to write
        assert!(with_section(hub, &[], &local).is_none());
    }

    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-hubs-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("knowledge")).unwrap();
        dir
    }

    fn write(root: &Path, rel: &str, body: &str) {
        let f = root.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(f, body).unwrap();
    }

    #[test]
    fn refresh_links_each_export_from_its_hub_and_writes_only_on_change() {
        let root = vault("refresh");
        write(
            &root,
            "knowledge/domains.toml",
            "[[domain]]\nid = \"core/ops\"\nis = \"ship\"\nrepo_docs = [\"home/docs/*.md\"]\n\n[[domain]]\nid = \"subjects/finance\"\nis = \"money\"\nrepo_docs = [\"home/docs/finance/**\"]\n\n[[domain]]\nid = \"core/ghost\"\nis = \"no hub\"\nrepo_docs = [\"home/docs/ghost.md\"]\n",
        );
        write(&root, "knowledge/core/ops/index.md", "# Ops\n\nhand text\n");
        write(&root, "knowledge/subjects/finance/index.md", "# Finance\n");
        write(
            &root,
            ".repos/home/docs/Budget.md",
            "# Monthly budget\n\nx\n",
        );
        write(
            &root,
            ".repos/home/docs/finance/Tax.md",
            "---\nt: 1\n---\n# Tax [year]\n",
        );
        write(&root, ".repos/home/docs/.stamps/skip.md", "# skip\n");
        let p = config::test_profile(root.to_str().unwrap());
        let log = Logger::new(root.join(".state/journal.log"), false);

        let wrote = refresh(&p, &log).unwrap();
        assert_eq!(wrote.len(), 2, "{wrote:?}");
        let ops = fs::read_to_string(root.join("knowledge/core/ops/index.md")).unwrap();
        assert!(
            ops.contains("## Repo docs\n\n- [[.repos/home/docs/Budget|Monthly budget]]\n"),
            "{ops}"
        );
        assert!(ops.starts_with("# Ops\n\nhand text\n"), "{ops}");
        let fin = fs::read_to_string(root.join("knowledge/subjects/finance/index.md")).unwrap();
        assert!(
            fin.contains("- [[.repos/home/docs/finance/Tax|Tax year]]"),
            "{fin}"
        );
        assert!(!ops.contains("skip") && !fin.contains("skip"));
        // the second run changes nothing
        assert!(refresh(&p, &log).unwrap().is_empty());
        // a removed export drops its bullet
        fs::remove_file(root.join(".repos/home/docs/Budget.md")).unwrap();
        assert_eq!(refresh(&p, &log).unwrap().len(), 1);
        let ops = fs::read_to_string(root.join("knowledge/core/ops/index.md")).unwrap();
        assert_eq!(ops, "# Ops\n\nhand text\n");
        // a machine with no export touches nothing
        fs::remove_dir_all(root.join(".repos")).unwrap();
        assert!(refresh(&p, &log).unwrap().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_title_is_the_first_heading_outside_a_code_fence() {
        let root = vault("title");
        write(
            &root,
            ".repos/c/a.md",
            "---\ntags: x\n---\n```bash\n# install deps\n```\n# Runbook\n",
        );
        assert_eq!(title(&root, "c/a.md"), "Runbook");
        write(&root, ".repos/c/b.md", "```\n# only code\n```\n");
        assert_eq!(title(&root, "c/b.md"), "b");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_exported_doc_no_domain_routes_is_listed() {
        let root = vault("unrouted");
        write(
            &root,
            "knowledge/domains.toml",
            "[[domain]]\nid = \"core/ops\"\nis = \"ship\"\nrepo_docs = [\"home/docs/a.md\"]\n",
        );
        write(&root, ".repos/home/docs/a.md", "# A\n");
        write(&root, ".repos/home/docs/b.md", "# B\n");
        let p = config::test_profile(root.to_str().unwrap());
        let reg = registry::load(&p).unwrap().unwrap();
        assert_eq!(unrouted(&p, &reg), vec!["home/docs/b.md".to_string()]);
        let _ = fs::remove_dir_all(&root);
    }
}
